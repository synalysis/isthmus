defmodule Isthmus.Gateway.Translator do
  @moduledoc """
  Routes normalized messages across registration-group legs.

  Trust boundary: Isthmus decrypts/re-encrypts at the edge.

  Nostr path uses a **per-group proxy** nsec (minted on the registration/bridge):
  - outbound DMs to member/primary npubs are sent *from* that group's proxy
  - inbound gift-wraps addressed to a proxy (`#p` / decrypt) route to that group
  - optional NIP-17 `subject` (`isthmus/<slug>`) remains a secondary room hint
  - `ISTHMUS_NOSTR_NSEC` is a legacy shared fallback inbox/sender when no proxy exists
  """
  use GenServer

  require Logger

  alias Isthmus.Announce.Governor
  alias Isthmus.Gateway
  alias Isthmus.Gateway.Message
  alias Isthmus.Networks.MeshCore.Companion
  alias Isthmus.Networks.Nostr.RelayPool
  alias Isthmus.Networks.Reticulum.Sidecar
  alias Isthmus.Nostr.Crypto
  alias Isthmus.Policy
  alias Isthmus.Registrations
  alias Isthmus.Tunnel.Outbox

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def ingest(%Message{} = msg), do: GenServer.cast(__MODULE__, {:ingest, msg})

  def ingest(attrs) when is_map(attrs) do
    msg = struct(Message, Map.merge(%{meta: %{}}, Map.new(attrs)))
    ingest(msg)
  end

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(Isthmus.PubSub, "nostr:inbound")
    Phoenix.PubSub.subscribe(Isthmus.PubSub, "meshcore:inbound")
    Phoenix.PubSub.subscribe(Isthmus.PubSub, "reticulum:inbound")
    {:ok, %{processed: 0, seen_ids: %{}}}
  end

  @impl true
  def handle_cast({:ingest, %Message{} = msg}, state) do
    case dedupe(state, msg.external_id) do
      {:duplicate, state} ->
        {:noreply, state}

      {:ok, state} ->
        _ = bridge(msg)
        {:noreply, update_in(state.processed, &(&1 + 1))}
    end
  end

  @impl true
  def handle_info({:event, _url, event}, state) when is_map(event) do
    _ = handle_nostr_event(event)
    {:noreply, state}
  end

  def handle_info({:meshcore_dm, attrs}, state) when is_map(attrs) do
    ingest(%Message{
      from_network: :meshcore,
      from_ref: attrs[:from_ref] || attrs["from_ref"],
      to_ref: attrs[:to_ref] || attrs["to_ref"],
      body: attrs[:body] || attrs["body"] || "",
      external_id: attrs[:external_id],
      meta: attrs[:meta] || %{}
    })

    {:noreply, state}
  end

  def handle_info({:meshcore_channel, attrs}, state) when is_map(attrs) do
    channel_idx = attrs[:channel_idx] || attrs["channel_idx"]
    meta = Map.merge(attrs[:meta] || attrs["meta"] || %{}, %{"meshcore_channel" => channel_idx})

    ingest(%Message{
      from_network: :meshcore,
      from_ref: nil,
      to_ref: nil,
      body: attrs[:body] || attrs["body"] || "",
      external_id:
        attrs[:external_id] || "mc-ch-#{channel_idx}-#{System.unique_integer([:positive])}",
      meta: meta
    })

    {:noreply, state}
  end

  def handle_info({:lxmf, attrs}, state) when is_map(attrs) do
    ingest(%Message{
      from_network: :reticulum,
      from_ref: attrs["from"] || attrs[:from],
      to_ref: attrs["to"] || attrs[:to],
      body: attrs["body"] || attrs[:body] || "",
      external_id: attrs["id"],
      meta: %{}
    })

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp handle_nostr_event(%{"kind" => kind} = event) when kind in [4, 14, 1059] do
    inboxes = Registrations.list_nostr_inbox_keypairs()

    if inboxes == [] do
      Logger.debug("nostr DM ignored (no proxy or ISTHMUS_NOSTR_NSEC)")
      :ok
    else
      case decrypt_nostr_with_inboxes(event, kind, inboxes) do
        {:ok, body, author, meta, to_hex} ->
          if kind == 1059 and not is_binary(meta["subject"] || meta[:subject]) do
            Logger.debug("nostr NIP-17 DM missing subject — routing by recipient proxy")
          end

          ingest(%Message{
            from_network: :nostr,
            from_ref: author,
            to_ref: to_hex,
            body: body,
            external_id: event["id"],
            meta: Map.merge(%{"kind" => kind}, stringify_meta(meta))
          })

        {:error, reason} ->
          Logger.debug("nostr DM decrypt failed: #{inspect(reason)}")
          :ok
      end
    end
  rescue
    e ->
      Logger.warning("nostr DM handler crashed: #{Exception.message(e)}")
      :ok
  end

  defp handle_nostr_event(_), do: :ok

  defp decrypt_nostr_with_inboxes(event, kind, inboxes) do
    p_hexes = p_tag_pubkeys(event)

    ordered =
      if p_hexes == [] do
        inboxes
      else
        matching = Enum.filter(inboxes, fn {pk, _} -> pk in p_hexes end)
        rest = Enum.reject(inboxes, fn {pk, _} -> pk in p_hexes end)
        if matching == [], do: inboxes, else: matching ++ rest
      end

    Enum.find_value(ordered, fn {pk, seckey} ->
      should_try? = kind == 1059 or tagged_p?(event, pk)

      if should_try? do
        case Crypto.decrypt_inbound(seckey, event) do
          {:ok, body, author, meta} -> {:ok, body, author, meta, pk}
          _ -> nil
        end
      end
    end) || {:error, :decrypt_failed}
  end

  defp p_tag_pubkeys(event) do
    (event["tags"] || [])
    |> Enum.flat_map(fn
      ["p", pk | _] when is_binary(pk) -> [String.downcase(pk)]
      _ -> []
    end)
    |> Enum.uniq()
  end

  defp tagged_p?(event, hex) do
    hex in p_tag_pubkeys(event)
  end

  defp bridge(%Message{body: body} = msg) when body in [nil, ""] do
    Gateway.log(log_attrs(msg, "none", "dropped", "empty_body"))
  end

  defp bridge(%Message{} = msg) do
    {group, msg} = resolve_group(msg)

    case group do
      nil ->
        Gateway.log(log_attrs(msg, "none", "dropped", "no_registration"))

      group ->
        targets = Registrations.other_legs(group, msg.from_network, msg.from_ref)

        Enum.each(targets, fn leg ->
          deliver(group, msg, leg)
        end)

        maybe_deliver_meshcore_channel(group, msg)
    end
  end

  # Returns {group | nil, msg} — msg may have @token stripped from body.
  # Prefer recipient (proxy) → subject room → author leg.
  defp resolve_group(%Message{from_network: :nostr} = msg) do
    subject = msg.meta["subject"] || msg.meta[:subject]
    to = msg.to_ref && String.downcase(msg.to_ref)
    from = msg.from_ref && String.downcase(msg.from_ref)

    group =
      (is_binary(to) && Registrations.find_by_leg(:nostr, to)) ||
        (is_binary(subject) && Registrations.find_by_nostr_subject(subject)) ||
        (is_binary(from) && Registrations.find_by_leg(:nostr, from))

    {group, msg}
  end

  defp resolve_group(%Message{from_network: :meshcore} = msg) do
    {group, msg} = resolve_meshcore_group(msg)
    {group, msg}
  end

  defp resolve_group(%Message{from_network: net, to_ref: to} = msg)
       when net in [:reticulum, "reticulum"] do
    group =
      (is_binary(to) && Registrations.find_by_leg(:reticulum, String.downcase(to))) ||
        (is_binary(msg.from_ref) &&
           Registrations.find_by_leg(:reticulum, String.downcase(msg.from_ref))) ||
        single_active_group()

    {group, msg}
  end

  defp resolve_group(%Message{from_network: net, from_ref: from} = msg) when is_binary(from) do
    {Registrations.find_by_leg(net, from) || single_active_group(), msg}
  end

  defp resolve_group(msg), do: {nil, msg}

  defp resolve_meshcore_group(%Message{} = msg) do
    channel_idx = meshcore_channel_idx(msg)

    cond do
      not is_nil(channel_idx) ->
        {Registrations.find_by_meshcore_channel(channel_idx), msg}

      true ->
        resolve_meshcore_dm_group(msg)
    end
  end

  defp resolve_meshcore_dm_group(%Message{} = msg) do
    from = msg.from_ref && String.downcase(msg.from_ref)
    to = msg.to_ref && String.downcase(msg.to_ref)

    cond do
      is_binary(from) && Registrations.find_by_leg(:meshcore, from) ->
        {Registrations.find_by_leg(:meshcore, from), msg}

      token = extract_address_token(msg.body) ->
        case Registrations.find_by_token(token) do
          nil ->
            {single_active_group(), msg}

          group ->
            {group, strip_address_token(msg, token)}
        end

      is_binary(to) && Registrations.find_by_leg(:meshcore, to) ->
        {Registrations.find_by_leg(:meshcore, to), msg}

      true ->
        {single_active_group(), msg}
    end
  end

  defp meshcore_channel_idx(%Message{meta: meta}) when is_map(meta) do
    case meta["meshcore_channel"] || meta[:meshcore_channel] do
      idx when is_integer(idx) -> idx
      idx when is_binary(idx) -> String.to_integer(idx)
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp meshcore_channel_idx(_), do: nil

  # Leading "@name" or "@deadbeef" used to disambiguate MeshCore ingress.
  defp extract_address_token(body) when is_binary(body) do
    case Regex.run(~r/^\s*@([A-Za-z0-9_-]{2,64})\b/, body) do
      [_, token] -> token
      _ -> nil
    end
  end

  defp extract_address_token(_), do: nil

  defp strip_address_token(%Message{body: body} = msg, token) when is_binary(body) do
    stripped =
      body
      |> String.replace(~r/^\s*@#{Regex.escape(token)}\b\s*/i, "")
      |> String.trim_leading()

    %{msg | body: stripped}
  end

  defp single_active_group do
    case Enum.filter(Registrations.list_all(), &(&1.status == "active")) do
      [only] -> only
      _ -> nil
    end
  end

  defp deliver(group, msg, leg) do
    network = leg.network

    case Policy.allow_gateway_direction?(msg.from_network, network) do
      {:drop, reason} ->
        Gateway.log(
          log_attrs(msg, network, "dropped", "policy:#{reason}",
            to_ref: leg.identity_ref,
            registration_group_id: group.id
          )
        )

      :ok ->
        case Governor.allow?(:gateway_message, network, leg.identity_ref) do
          {:drop, reason} ->
            Gateway.log(
              log_attrs(msg, network, "dropped", "governor:#{reason}",
                to_ref: leg.identity_ref,
                registration_group_id: group.id
              )
            )

          :ok ->
            result =
              case network do
                "meshcore" -> send_meshcore(group, leg, msg)
                "reticulum" -> send_reticulum(group, leg, msg)
                "nostr" -> send_nostr(group, leg, msg)
                _ -> {:error, :unknown_network}
              end

            {status, error, log_opts} =
              case result do
                :ok ->
                  {"delivered", nil, [to_ref: leg.identity_ref]}

                {:ok, meta} when is_map(meta) ->
                  {"delivered", nil,
                   [
                     to_ref: meta[:to] || meta["to"] || leg.identity_ref,
                     meta: meta
                   ]}

                {:error, %{reason: reason} = detail} ->
                  {"failed", error_string(reason),
                   [
                     to_ref: detail[:to] || detail["to"] || leg.identity_ref,
                     meta: detail
                   ]}

                {:error, reason} ->
                  {"failed", error_string(reason), [to_ref: leg.identity_ref]}
              end

            Gateway.log(
              log_attrs(
                msg,
                network,
                status,
                error,
                [registration_group_id: group.id] ++ log_opts
              )
            )
        end
    end
  end

  # Persist route metadata only — never store message content in the activity log.
  defp log_attrs(msg, to_network, status, error, opts \\ []) do
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

  defp stringify_meta(meta) when is_map(meta) do
    Map.new(meta, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp stringify_meta(_), do: %{}

  defp error_string(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_string(reason) when is_binary(reason), do: reason
  defp error_string(reason), do: inspect(reason)

  defp send_meshcore(group, leg, msg) do
    case meshcore_destination(group, leg, msg) do
      {:ok, dest} -> Companion.send_text(dest, prefix_body(msg))
      {:error, _} = err -> err
    end
  end

  # primary/member → real MeshCore pubkey; proxy → last peer / env contact.
  defp meshcore_destination(group, leg, %Message{} = msg) do
    if Registrations.real_destination_leg?(leg) and mesh_pubkey?(leg.identity_ref) do
      {:ok, String.downcase(leg.identity_ref)}
    else
      meta_peer = msg.meta["mesh_peer"] || msg.meta[:mesh_peer]

      peer =
        cond do
          mesh_pubkey?(meta_peer) -> meta_peer
          true -> Gateway.last_mesh_peer(group.id) || System.get_env("ISTHMUS_MESHCORE_PEER")
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

  defp send_reticulum(group, leg, msg) do
    with {:ok, dest} <- reticulum_destination(group, leg, msg),
         {:ok, from_identity} <- ensure_reticulum_from(group) do
      case Sidecar.send_lxmf(%{
             "to" => dest,
             "from" => from_identity,
             "body" => prefix_body(msg),
             # DIRECT uses MeshChatX's backchannel link from the inbound DM.
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

  # Prefer the last LXMF peer we actually corresponded with (destination hash).
  # Attached MeshChatX legs are often the *identity* hash; LXMF uses lxmf.delivery.
  defp reticulum_destination(group, leg, %Message{} = msg) do
    meta_peer = msg.meta["rns_peer"] || msg.meta[:rns_peer]

    peer =
      cond do
        rns_dest?(meta_peer) -> meta_peer
        true -> Gateway.last_rns_peer(group.id) || System.get_env("ISTHMUS_RNS_PEER")
      end

    cond do
      Registrations.real_destination_leg?(leg) and rns_dest?(peer) ->
        {:ok, String.downcase(peer)}

      Registrations.real_destination_leg?(leg) and rns_dest?(leg.identity_ref) ->
        {:ok, String.downcase(leg.identity_ref)}

      rns_dest?(peer) and peer != leg.identity_ref ->
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
      leg -> leg.identity_ref
    end
  end

  defp reticulum_from_ref(_), do: nil

  defp rns_dest?(hex) when is_binary(hex), do: String.match?(hex, ~r/^[0-9a-fA-F]{32}$/)
  defp rns_dest?(_), do: false

  defp send_nostr(group, leg, msg) do
    group =
      case Registrations.ensure_nostr_proxy(group) do
        {:ok, g} -> g
        {:error, _} -> group
      end

    seckey =
      case Registrations.nostr_proxy_seckey(group) do
        {:ok, sk} ->
          {:ok, sk}

        {:error, _} ->
          case Crypto.service_keypair() do
            {:ok, sk, _} -> {:ok, sk}
            :none -> :none
            :invalid -> :invalid
          end
      end

    case seckey do
      {:ok, sk} ->
        subject = Registrations.nostr_room_subject(group)
        opts = [subject: subject]

        case Crypto.dm_events(sk, leg.identity_ref, prefix_body(msg), opts) do
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
              :ok -> {:ok, %{to: leg.identity_ref, subject: subject}}
              {:error, _} = err -> err
            end

          {:error, reason} ->
            {:error, reason}
        end

      :none ->
        Outbox.enqueue("gateway:nostr", leg.identity_ref, prefix_body(msg), %{
          "note" => "mint a Nostr proxy (or set ISTHMUS_NOSTR_NSEC) to enable Nostr DM delivery"
        })

        {:error, :no_nostr_sender}

      :invalid ->
        {:error, :invalid_service_nsec}
    end
  end

  defp prefix_body(%Message{} = msg) do
    "[via Isthmus/#{msg.from_network}] #{msg.body}"
  end

  defp maybe_deliver_meshcore_channel(%{meshcore_channel_idx: idx} = group, msg)
       when not is_nil(idx) do
    ingress = meshcore_channel_idx(msg)

    if ingress == idx do
      :ok
    else
      deliver_meshcore_channel(group, msg, idx)
    end
  end

  defp maybe_deliver_meshcore_channel(_, _), do: :ok

  defp deliver_meshcore_channel(group, msg, idx) do
    case Policy.allow_gateway_direction?(msg.from_network, "meshcore") do
      {:drop, reason} ->
        Gateway.log(
          log_attrs(msg, "meshcore", "dropped", "policy:#{reason}",
            to_ref: "channel:#{idx}",
            registration_group_id: group.id
          )
        )

      :ok ->
        case Governor.allow?(:gateway_message, "meshcore", "channel:#{idx}") do
          {:drop, reason} ->
            Gateway.log(
              log_attrs(msg, "meshcore", "dropped", "governor:#{reason}",
                to_ref: "channel:#{idx}",
                registration_group_id: group.id
              )
            )

          :ok ->
            result = Companion.send_channel_text(idx, prefix_body(msg))

            {status, error} =
              case result do
                :ok -> {"delivered", nil}
                {:ok, _} -> {"delivered", nil}
                {:error, reason} -> {"failed", inspect(reason)}
              end

            Gateway.log(
              log_attrs(msg, "meshcore", status, error,
                to_ref: "channel:#{idx}",
                registration_group_id: group.id
              )
            )
        end
    end
  end

  # Keep a bounded set of recent external ids to suppress relay/mesh duplicates.
  defp dedupe(state, nil), do: {:ok, state}
  defp dedupe(state, ""), do: {:ok, state}

  defp dedupe(%{seen_ids: seen} = state, id) when is_binary(id) do
    if Map.has_key?(seen, id) do
      {:duplicate, state}
    else
      seen =
        seen
        |> Map.put(id, System.system_time(:second))
        |> trim_seen(200)

      {:ok, %{state | seen_ids: seen}}
    end
  end

  defp trim_seen(seen, max) when map_size(seen) <= max, do: seen

  defp trim_seen(seen, max) do
    seen
    |> Enum.sort_by(fn {_id, ts} -> ts end, :desc)
    |> Enum.take(max)
    |> Map.new()
  end
end
