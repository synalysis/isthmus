defmodule Isthmus.Gateway.Deliver do
  @moduledoc false

  alias Isthmus.Announce.Governor
  alias Isthmus.Gateway
  alias Isthmus.Gateway.Message
  alias Isthmus.Gateway.Resolve
  alias Isthmus.Networks.Agent.Bridge, as: AgentBridge
  alias Isthmus.Networks.MeshCore
  alias Isthmus.Networks.MeshCore.Companion
  alias Isthmus.Networks.MeshCore.SyntheticNode
  alias Isthmus.Networks.Meshtastic.Companion, as: MeshtasticCompanion
  alias Isthmus.Networks.Nostr.RelayPool
  alias Isthmus.Networks.Reticulum.Sidecar
  alias Isthmus.Nostr.Crypto
  alias Isthmus.Policy
  alias Isthmus.Registrations
  alias Isthmus.Tunnel.Outbox

  @type group :: Isthmus.Registrations.RegistrationGroup.t()
  @type leg :: Isthmus.Registrations.IdentityLeg.t()
  @type msg :: Message.t()

  @spec leg(group(), msg(), leg()) ::
          :drop | {:ok, Isthmus.Gateway.Activity.t()} | {:error, Ecto.Changeset.t()}
  def leg(group, msg, dest_leg) do
    network = dest_leg.network

    with :ok <- allow_or_log(group, msg, network, dest_leg.identity_ref),
         :ok <- govern_or_log(group, msg, network, dest_leg.identity_ref) do
      log_send_result(group, msg, network, dest_leg, send_to(group, dest_leg, msg))
    end
  end

  @spec channels(group(), msg()) :: :ok
  def channels(group, msg) do
    deliver_network_channels(group, msg, "meshcore")
    deliver_network_channels(group, msg, "meshtastic")
    :ok
  end

  @spec log_attrs(msg(), String.t(), String.t(), String.t() | nil) :: map()
  @spec log_attrs(msg(), String.t(), String.t(), String.t() | nil, keyword()) :: map()
  def log_attrs(msg, to_network, status, error, opts \\ []) do
    body = msg.body || ""
    extra_meta = Keyword.get(opts, :meta, %{})

    %{
      direction: "bridge",
      from_network: to_string(msg.from_network),
      to_network: to_network,
      from_ref: msg.from_ref,
      to_ref: Keyword.get(opts, :to_ref, msg.to_ref),
      body: "",
      status: status,
      error: error,
      registration_group_id: Keyword.get(opts, :registration_group_id),
      external_id: msg.external_id,
      meta: Map.merge(%{"body_bytes" => byte_size(body)}, stringify_meta(extra_meta))
    }
  end

  @spec stringify_meta(term()) :: map()
  def stringify_meta(meta) when is_map(meta) do
    Map.new(meta, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  def stringify_meta(_), do: %{}

  defp deliver_network_channels(group, msg, network) do
    src_idx = Resolve.channel_idx(msg, network)
    src_radio = Resolve.radio_id(msg)

    for link <- channel_links(group, network) do
      if echo_on_same_radio_channel?(link.channel_idx, src_idx, link.device_id, src_radio) do
        :ok
      else
        deliver_channel(group, msg, network, link)
      end
    end
  end

  defp deliver_channel(group, msg, network, link) do
    idx = link.channel_idx
    to_ref = "channel:#{idx}"

    with :ok <- allow_or_log(group, msg, network, to_ref),
         :ok <- govern_or_log(group, msg, network, to_ref) do
      result = send_channel(network, idx, prefix_body(msg), link.device_id)
      {status, error} = channel_status(result)

      Gateway.log(
        log_attrs(msg, network, status, error,
          to_ref: to_ref,
          registration_group_id: group.id
        )
      )
    end
  end

  defp send_channel("meshcore", idx, body, device_id) do
    Companion.send_channel_text(idx, body, Companion.port_for_radio_id(device_id))
  end

  defp send_channel("meshtastic", idx, body, device_id) do
    MeshtasticCompanion.send_channel_text(
      idx,
      body,
      MeshtasticCompanion.port_for_radio_id(device_id)
    )
  end

  defp channel_status(:ok), do: {"delivered", nil}
  defp channel_status({:ok, _}), do: {"delivered", nil}
  defp channel_status({:error, reason}), do: {"failed", inspect(reason)}

  defp channel_links(group, network) do
    case Registrations.radio_links(group, network) do
      [_ | _] = links -> links
      [] -> fallback_channel_link(group, network)
    end
  end

  defp fallback_channel_link(group, "meshcore") do
    case group do
      %{meshcore_channel_idx: idx} when not is_nil(idx) ->
        [%{channel_idx: idx, device_id: group.meshcore_channel_device_id}]

      _ ->
        []
    end
  end

  defp fallback_channel_link(group, "meshtastic") do
    case group do
      %{meshtastic_channel_idx: idx} when not is_nil(idx) ->
        [%{channel_idx: idx, device_id: group.meshtastic_channel_device_id}]

      _ ->
        []
    end
  end

  defp fallback_channel_link(_, _), do: []

  defp echo_on_same_radio_channel?(idx, ingress, group_radio, msg_radio) do
    ingress == idx and
      (is_nil(Registrations.normalize_radio_id(group_radio)) or
         same_radio_id?(group_radio, msg_radio))
  end

  defp same_radio_id?(a, b) do
    Registrations.normalize_radio_id(a) != nil and
      Registrations.normalize_radio_id(a) == Registrations.normalize_radio_id(b)
  end

  defp allow_or_log(group, msg, network, to_ref) do
    case allow_direction?(msg.from_network, network) do
      {:drop, reason} ->
        Gateway.log(
          log_attrs(msg, network, "dropped", "policy:#{reason}",
            to_ref: to_ref,
            registration_group_id: group.id
          )
        )

        :drop

      :ok ->
        :ok
    end
  end

  defp govern_or_log(group, msg, network, to_ref) do
    case Governor.allow?(:gateway_message, network, to_ref) do
      {:drop, reason} ->
        Gateway.log(
          log_attrs(msg, network, "dropped", "governor:#{reason}",
            to_ref: to_ref,
            registration_group_id: group.id
          )
        )

        :drop

      :ok ->
        :ok
    end
  end

  defp send_to(group, dest_leg, msg) do
    case dest_leg.network do
      "meshcore" -> send_meshcore(group, dest_leg, msg)
      "meshtastic" -> MeshtasticCompanion.send_text(dest_leg.identity_ref, prefix_body(msg))
      "reticulum" -> send_reticulum(group, dest_leg, msg)
      "nostr" -> send_nostr(group, dest_leg, msg)
      "agent" -> send_agent(group, dest_leg, msg)
      _ -> {:error, :unknown_network}
    end
  end

  defp log_send_result(group, msg, network, dest_leg, result) do
    {status, error, log_opts} =
      case result do
        :ok ->
          {"delivered", nil, [to_ref: dest_leg.identity_ref]}

        {:ok, meta} when is_map(meta) ->
          {"delivered", nil,
           [to_ref: meta[:to] || meta["to"] || dest_leg.identity_ref, meta: meta]}

        {:error, %{reason: reason} = detail} ->
          {"failed", error_string(reason),
           [to_ref: detail[:to] || detail["to"] || dest_leg.identity_ref, meta: detail]}

        {:error, reason} ->
          {"failed", error_string(reason), [to_ref: dest_leg.identity_ref]}
      end

    Gateway.log(
      log_attrs(msg, network, status, error, [registration_group_id: group.id] ++ log_opts)
    )
  end

  defp send_meshcore(group, dest_leg, msg) do
    case meshcore_destination(group, dest_leg, msg) do
      {:ok, dest} -> dispatch_meshcore(group, dest, prefix_body(msg))
      {:error, _} = err -> err
    end
  end

  defp dispatch_meshcore(group, dest, body) do
    if match?(%{status: :online}, MeshCore.BridgeLink.health()) do
      send_meshcore_via_bridge(group, dest, body)
    else
      Companion.send_text(dest, body)
    end
  end

  defp send_meshcore_via_bridge(group, dest, body) do
    case Registrations.ensure_meshcore_proxy(group) do
      {:ok, group} ->
        case Registrations.meshcore_proxy_leg(group) do
          nil ->
            Companion.send_text(dest, body)

          proxy ->
            case SyntheticNode.send_text(proxy, dest, body) do
              :ok -> :ok
              {:error, _} -> Companion.send_text(dest, body)
            end
        end

      {:error, _} ->
        Companion.send_text(dest, body)
    end
  end

  defp meshcore_destination(group, dest_leg, %Message{} = msg) do
    if Registrations.real_destination_leg?(dest_leg) and mesh_pubkey?(dest_leg.identity_ref) do
      {:ok, String.downcase(dest_leg.identity_ref)}
    else
      meta_peer = msg.meta["mesh_peer"] || msg.meta[:mesh_peer]

      peer =
        if mesh_pubkey?(meta_peer) do
          meta_peer
        else
          Gateway.last_mesh_peer(group.id) || System.get_env("ISTHMUS_MESHCORE_PEER")
        end

      if mesh_pubkey?(peer) do
        {:ok, String.downcase(peer)}
      else
        {:error, :no_meshcore_peer}
      end
    end
  end

  defp mesh_pubkey?(hex) when is_binary(hex), do: String.match?(hex, ~r/^[0-9a-fA-F]{64}$/)
  defp mesh_pubkey?(_), do: false

  defp send_reticulum(group, dest_leg, msg) do
    with {:ok, dest} <- reticulum_destination(group, dest_leg, msg),
         {:ok, from_identity} <- ensure_reticulum_from(group) do
      case Sidecar.send_lxmf(%{
             "to" => dest,
             "from" => from_identity,
             "body" => prefix_body(msg),
             "method" => "direct",
             "wait_seconds" => 12,
             "from_network" => to_string(msg.from_network)
           }) do
        :ok ->
          {:ok, %{to: dest, from: from_identity, method: "direct"}}

        {:ok, reply} when is_map(reply) ->
          {:ok,
           %{
             to: reply["to"] || dest,
             from: reply["from"] || from_identity,
             to_requested: reply["to_requested"],
             resolved_from_identity_hash: reply["resolved_from_identity_hash"],
             method: reply["method"],
             state: reply["state"],
             path_known: reply["path_known"],
             backchannel: reply["backchannel"],
             direct_link: reply["direct_link"]
           }}

        {:error, reason, detail} when is_map(detail) ->
          {:error,
           %{
             reason: reason,
             state: detail["state"],
             method: detail["method"],
             path_known: detail["path_known"],
             backchannel: detail["backchannel"],
             direct_link: detail["direct_link"],
             to: detail["to"],
             from: detail["from"]
           }}

        {:error, reason, _} ->
          {:error, reason}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp reticulum_destination(group, dest_leg, %Message{} = msg) do
    meta_peer = msg.meta["rns_peer"] || msg.meta[:rns_peer]

    peer =
      if rns_dest?(meta_peer) do
        meta_peer
      else
        Gateway.last_rns_peer(group.id) || System.get_env("ISTHMUS_RNS_PEER")
      end

    cond do
      Registrations.real_destination_leg?(dest_leg) and rns_dest?(peer) ->
        {:ok, String.downcase(peer)}

      Registrations.real_destination_leg?(dest_leg) and rns_dest?(dest_leg.identity_ref) ->
        {:ok, String.downcase(dest_leg.identity_ref)}

      rns_dest?(peer) and peer != dest_leg.identity_ref ->
        {:ok, String.downcase(peer)}

      true ->
        {:error, :no_reticulum_peer}
    end
  end

  defp ensure_reticulum_from(group) do
    case reticulum_from_ref(group) do
      nil ->
        {:error, :no_reticulum_proxy}

      from_ref ->
        case Enum.find(group.legs, &(&1.network == "reticulum" and &1.identity_ref == from_ref)) do
          %{} = proxy ->
            case Registrations.ensure_reticulum_ready(proxy) do
              {:ok, ready} -> {:ok, ready.identity_ref}
              {:error, _} = err -> err
            end

          nil ->
            {:ok, from_ref}
        end
    end
  end

  defp reticulum_from_ref(%{legs: legs}) when is_list(legs) do
    legs
    |> Enum.filter(&(&1.network == "reticulum" and &1.role == "proxy"))
    |> List.first()
    |> case do
      nil -> nil
      dest_leg -> dest_leg.identity_ref
    end
  end

  defp reticulum_from_ref(_), do: nil

  defp rns_dest?(hex) when is_binary(hex), do: String.match?(hex, ~r/^[0-9a-fA-F]{32}$/)
  defp rns_dest?(_), do: false

  defp send_nostr(group, dest_leg, msg) do
    group =
      case Registrations.ensure_nostr_proxy(group) do
        {:ok, g} -> g
        {:error, _} -> group
      end

    case Registrations.nostr_proxy_seckey(group) do
      {:ok, sk} ->
        publish_nostr_dm(group, dest_leg, msg, sk)

      {:error, reason} ->
        Outbox.enqueue("gateway:nostr", dest_leg.identity_ref, prefix_body(msg), %{
          "note" => "mint a Nostr proxy for this group to enable Nostr DM delivery",
          "reason" => error_string(reason)
        })

        {:error, :no_nostr_proxy}
    end
  end

  defp publish_nostr_dm(group, dest_leg, msg, sk) do
    subject = Registrations.nostr_room_subject(group)

    case Crypto.dm_events(sk, dest_leg.identity_ref, prefix_body(msg), subject: subject) do
      {:ok, events} ->
        result =
          Enum.reduce_while(events, :ok, fn event, :ok ->
            case RelayPool.publish_event(event) do
              :ok -> {:cont, :ok}
              {:ok, _} -> {:cont, :ok}
              {:error, _} = err -> {:halt, err}
            end
          end)

        case result do
          :ok -> {:ok, %{to: dest_leg.identity_ref, subject: subject}}
          {:error, _} = err -> err
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_agent(group, dest_leg, msg) do
    from = msg.from_ref || "unknown"

    prompt = """
    Message in Isthmus group #{group.display_name} from #{msg.from_network}/#{from}:

    #{msg.body}

    Reply with a short plain-text message suitable for a LoRa mesh. No markdown.
    """

    AgentBridge.prompt(dest_leg.identity_ref, prompt, %{
      "group_id" => group.id,
      "from_network" => to_string(msg.from_network),
      "from_ref" => from
    })
  end

  defp prefix_body(%Message{} = msg) do
    "[via Isthmus/#{msg.from_network}] #{msg.body}"
  end

  defp allow_direction?(from, _to) when from in [:admin, "admin"], do: :ok
  defp allow_direction?(from, to), do: Policy.allow_gateway_direction?(from, to)

  defp error_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_string(reason) when is_binary(reason), do: reason
  defp error_string(reason), do: inspect(reason)
end
