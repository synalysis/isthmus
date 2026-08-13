defmodule Isthmus.MCP.Tools do
  @moduledoc false

  alias Isthmus.Accounts
  alias Isthmus.Announce.Governor
  alias Isthmus.Announce.Sightings
  alias Isthmus.Audit
  alias Isthmus.Gateway
  alias Isthmus.Gateway.Message
  alias Isthmus.Gateway.Translator
  alias Isthmus.Networks.Health
  alias Isthmus.Networks.MeshCore.Companion, as: MeshCoreCompanion
  alias Isthmus.Networks.Meshtastic.Companion, as: MeshtasticCompanion
  alias Isthmus.Nostr.Bech32
  alias Isthmus.Policy
  alias Isthmus.Registrations
  alias Isthmus.Relays
  alias Isthmus.Topology
  alias Isthmus.Tunnel

  @writable_policy ~w(
    registration_open
    announce_min_interval_sec
    nostr_publish_budget_per_hour
    gateway_allow_directions
    gateway_deny_directions
    tunnel_block_meshcore_public
  )

  def health(_args \\ %{}) do
    reports =
      Enum.map(Health.report_all(), fn r ->
        %{
          network: r.network,
          label: r.label,
          status: r.status,
          severity: r.severity,
          summary: r.summary,
          issue: r.issue,
          fix: r.fix,
          meta: Enum.map(r.meta || [], fn {k, v} -> %{key: k, value: v} end)
        }
      end)

    {:ok, %{reports: reports}}
  end

  def list_groups(_args \\ %{}) do
    groups =
      Registrations.list_all()
      |> Enum.map(&dump_group/1)

    {:ok, %{groups: groups}}
  end

  def get_group(args) do
    with {:ok, group} <- resolve_group(fetch(args, :group)) do
      {:ok, dump_group(group)}
    end
  end

  def create_group(args) do
    name = args |> fetch(:name) |> to_string() |> String.trim()

    cond do
      name == "" ->
        {:error, "name is required"}

      true ->
        with {:ok, owner} <- resolve_owner(fetch(args, :owner)) do
          case Registrations.create_bridge_group(owner, %{
                 display_name: name,
                 created_by: "admin"
               }) do
            {:ok, group} -> {:ok, dump_group(group)}
            {:error, reason} -> {:error, format_error(reason)}
          end
        end
    end
  end

  def attach_member(args) do
    with {:ok, group} <- resolve_group(fetch(args, :group)),
         {:ok, network} <- require_text(args, :network),
         {:ok, identity} <- require_text(args, :identity) do
      case Registrations.attach_member(group, network, identity) do
        {:ok, group} -> {:ok, dump_group(group)}
        {:error, reason} -> {:error, format_error(reason)}
      end
    end
  end

  def detach_member(args) do
    with {:ok, group} <- resolve_group(fetch(args, :group)),
         {:ok, identity} <- require_text(args, :identity) do
      network = optional_text(args, :network)

      leg =
        Enum.find(group.legs || [], fn leg ->
          String.downcase(leg.identity_ref) == String.downcase(identity) and
            (is_nil(network) or leg.network == network)
        end)

      case leg && Registrations.detach_member(leg) do
        :ok -> {:ok, dump_group(Registrations.get_group!(group.id))}
        nil -> {:error, "member not found"}
        {:error, reason} -> {:error, format_error(reason)}
      end
    end
  end

  def inject_message(args) do
    with {:ok, group} <- resolve_group(fetch(args, :group)),
         {:ok, body} <- require_text(args, :body) do
      if group.status != "active" do
        {:error, "group is not active"}
      else
        Translator.ingest(%Message{
          from_network: :admin,
          from_ref: "admin",
          body: body,
          group_id: group.id,
          external_id: "mcp-#{System.unique_integer([:positive])}",
          meta: %{"injected_by" => "mcp"}
        })

        {:ok, %{ok: true, group_id: group.id, name: group.display_name, body: body}}
      end
    end
  end

  def announce_group(args) do
    with {:ok, group} <- resolve_group(fetch(args, :group)) do
      case Registrations.announce_group(group) do
        {:ok, results} ->
          {:ok,
           %{
             group_id: group.id,
             results:
               Enum.map(results, fn
                 {net, :ok} ->
                   %{network: net, ok: true}

                 {net, {:error, reason}} ->
                   %{network: net, ok: false, error: format_error(reason)}
               end)
           }}

        {:error, reason} ->
          {:error, format_error(reason)}
      end
    end
  end

  def mint_proxy(args) do
    with {:ok, group} <- resolve_group(fetch(args, :group)),
         {:ok, network} <- require_text(args, :network) do
      result =
        case network do
          "reticulum" -> Registrations.ensure_bridge_rns_proxy(group)
          "nostr" -> Registrations.ensure_nostr_proxy(group)
          "meshcore" -> Registrations.ensure_meshcore_proxy(group)
          _ -> {:error, "network must be reticulum, nostr, or meshcore"}
        end

      case result do
        {:ok, group} -> {:ok, dump_group(group)}
        {:error, reason} -> {:error, format_error(reason)}
      end
    end
  end

  def revoke_group(args) do
    with {:ok, group} <- resolve_group(fetch(args, :group)) do
      case Registrations.revoke(group) do
        {:ok, group} -> {:ok, dump_group(group)}
        {:error, reason} -> {:error, format_error(reason)}
      end
    end
  end

  def list_adverts(args) do
    limit = clamp_int(fetch(args, :limit), 50, 1, 200)
    network = optional_text(args, :network)

    opts =
      if network do
        [networks: [network], per_network: true]
      else
        []
      end

    rows =
      Sightings.list_recent(limit, opts)
      |> Enum.map(fn s ->
        %{
          id: s.id,
          at: s.seen_at,
          network: s.network,
          direction: s.direction,
          identity: s.identity_ref,
          hops: s.hops,
          name: get_in(s.meta || %{}, ["name"])
        }
      end)

    {:ok, %{adverts: rows}}
  end

  def list_tunnels(_args \\ %{}) do
    peers =
      Enum.map(Tunnel.list_peers(), fn p ->
        %{
          id: p.id,
          name: p.name,
          enabled: p.enabled,
          payload_network: p.payload_network,
          carrier_network: p.carrier_network,
          peer_ref: p.peer_ref,
          tunnel_id: p.tunnel_id
        }
      end)

    {:ok, %{tunnels: peers}}
  end

  def create_tunnel(args) do
    with {:ok, name} <- require_text(args, :name),
         {:ok, payload} <- require_text(args, :payload_network),
         {:ok, carrier} <- require_text(args, :carrier_network),
         {:ok, peer_ref} <- require_text(args, :peer_ref) do
      attrs = %{
        "name" => name,
        "payload_network" => payload,
        "carrier_network" => carrier,
        "peer_ref" => peer_ref,
        "pairing_code" => optional_text(args, :pairing_code),
        "tunnel_id" => optional_text(args, :tunnel_id),
        "enabled" => fetch(args, :enabled) != false
      }

      case Tunnel.create_peer(attrs) do
        {:ok, peer} -> {:ok, dump_tunnel(peer)}
        {:error, reason} -> {:error, format_error(reason)}
      end
    end
  end

  def set_tunnel_enabled(args) do
    with {:ok, peer} <- resolve_tunnel(fetch(args, :tunnel)),
         {:ok, enabled} <- require_bool(args, :enabled) do
      case Tunnel.update_peer(peer, %{enabled: enabled}) do
        {:ok, peer} -> {:ok, dump_tunnel(peer)}
        {:error, reason} -> {:error, format_error(reason)}
      end
    end
  end

  def list_relays(_args \\ %{}) do
    relays =
      Enum.map(Relays.list_relays(), fn r ->
        %{
          id: r.id,
          url: r.url,
          enabled: r.enabled,
          read: r.read,
          write: r.write,
          priority: r.priority
        }
      end)

    {:ok, %{relays: relays}}
  end

  def create_relay(args) do
    with {:ok, url} <- require_text(args, :url) do
      attrs = %{
        "url" => url,
        "enabled" => fetch(args, :enabled) != false,
        "read" => fetch(args, :read) != false,
        "write" => fetch(args, :write) != false
      }

      case Relays.create_relay(attrs) do
        {:ok, relay} ->
          {:ok,
           %{
             id: relay.id,
             url: relay.url,
             enabled: relay.enabled,
             read: relay.read,
             write: relay.write
           }}

        {:error, reason} ->
          {:error, format_error(reason)}
      end
    end
  end

  def list_timeline(args) do
    limit = clamp_int(fetch(args, :limit), 40, 1, 80)

    kinds =
      List.wrap(fetch(args, :kinds) || []) |> Enum.map(&to_string/1) |> Enum.reject(&(&1 == ""))

    opts = if kinds == [], do: [], else: [kinds: kinds]

    entries =
      Audit.timeline(limit, opts)
      |> Enum.map(fn e ->
        %{id: e.id, at: e.at, kind: e.kind, summary: e.summary, detail: e.detail}
      end)

    {:ok, %{entries: entries}}
  end

  def gateway_log(args) do
    limit = clamp_int(fetch(args, :limit), 30, 1, 100)

    {:ok, %{log: Gateway.list_forward_log(limit)}}
  end

  def governor_drops(_args \\ %{}) do
    {:ok, %{drops: Governor.drops_summary(20), stats: Governor.stats()}}
  end

  def get_policy(_args \\ %{}) do
    {:ok, %{settings: Policy.all_settings(), directions: Policy.direction_keys()}}
  end

  def set_policy(args) do
    with {:ok, key} <- require_text(args, :key) do
      if key not in @writable_policy do
        {:error, "unknown policy key: #{key}"}
      else
        value = coerce_policy(key, fetch(args, :value))

        case Policy.put(key, value) do
          {:ok, _} -> {:ok, %{key: key, value: Policy.get(key)}}
          {:error, reason} -> {:error, format_error(reason)}
        end
      end
    end
  end

  def list_radios(_args \\ %{}) do
    {:ok,
     %{
       meshcore: safe_health(&MeshCoreCompanion.list_health/0),
       meshtastic: safe_health(&MeshtasticCompanion.list_health/0)
     }}
  end

  def set_meshtastic_time(args) do
    port = optional_text(args, :port)
    tz = optional_text(args, :timezone)

    opts = if tz, do: [tz: tz], else: []

    case MeshtasticCompanion.set_time(port, opts) do
      :ok -> {:ok, %{ok: true}}
      {:ok, _} -> {:ok, %{ok: true}}
      {:error, reason} -> {:error, format_error(reason)}
    end
  end

  def topology(_args \\ %{}) do
    {:ok, Topology.build(:all)}
  end

  def list_admins(_args \\ %{}) do
    admins =
      Enum.map(Accounts.list_admins(), fn a ->
        %{id: a.id, npub: a.npub, pubkey_hex: a.pubkey_hex, label: a.label}
      end)

    {:ok, %{admins: admins}}
  end

  defp dump_group(group) do
    %{
      id: group.id,
      name: group.display_name,
      kind: group.kind,
      status: group.status,
      owner: group.owner_pubkey_hex,
      token: Registrations.token_slug(group.display_name),
      members:
        Enum.map(group.legs || [], fn leg ->
          %{
            id: leg.id,
            network: leg.network,
            role: leg.role,
            identity: leg.identity_ref
          }
        end),
      channels:
        Enum.map(group.radio_channels || [], fn ch ->
          %{
            id: ch.id,
            network: ch.network,
            device_id: ch.device_id,
            channel_idx: ch.channel_idx
          }
        end)
    }
  end

  defp dump_tunnel(peer) do
    %{
      id: peer.id,
      name: peer.name,
      enabled: peer.enabled,
      payload_network: peer.payload_network,
      carrier_network: peer.carrier_network,
      peer_ref: peer.peer_ref,
      tunnel_id: peer.tunnel_id
    }
  end

  defp resolve_group(nil), do: {:error, "group is required"}
  defp resolve_group(""), do: {:error, "group is required"}

  defp resolve_group(id_or_name) when is_binary(id_or_name) do
    trimmed = String.trim(id_or_name)

    by_id =
      case Ecto.UUID.cast(trimmed) do
        {:ok, _} -> Registrations.get_group(trimmed)
        :error -> nil
      end

    cond do
      is_map(by_id) ->
        {:ok, by_id}

      true ->
        name = String.downcase(trimmed)

        case Enum.find(
               Registrations.list_all(),
               &(String.downcase(&1.display_name || "") == name)
             ) do
          nil -> {:error, "group not found: #{trimmed}"}
          group -> {:ok, Registrations.get_group!(group.id)}
        end
    end
  end

  defp resolve_group(_), do: {:error, "group is required"}

  defp resolve_tunnel(nil), do: {:error, "tunnel is required"}
  defp resolve_tunnel(""), do: {:error, "tunnel is required"}

  defp resolve_tunnel(id_or_name) when is_binary(id_or_name) do
    trimmed = String.trim(id_or_name)
    peers = Tunnel.list_peers()

    found =
      Enum.find(peers, &(&1.id == trimmed)) ||
        Enum.find(peers, &(String.downcase(&1.name || "") == String.downcase(trimmed))) ||
        Enum.find(peers, &(&1.tunnel_id == trimmed))

    if found, do: {:ok, found}, else: {:error, "tunnel not found: #{trimmed}"}
  end

  defp resolve_owner(nil), do: default_owner()
  defp resolve_owner(""), do: default_owner()

  defp resolve_owner(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      String.match?(trimmed, ~r/\A[0-9a-f]{64}\z/i) ->
        {:ok, String.downcase(trimmed)}

      true ->
        case Bech32.decode(trimmed) do
          {:ok, "npub", pubkey} -> {:ok, Base.encode16(pubkey, case: :lower)}
          _ -> {:error, "owner must be an npub or 64-char hex pubkey"}
        end
    end
  end

  defp default_owner do
    case Accounts.list_admins() do
      [%{pubkey_hex: hex} | _] -> {:ok, hex}
      [] -> {:error, "no admin on file — pass owner as npub"}
    end
  end

  defp require_text(args, key) do
    case args |> fetch(key) |> to_string() |> String.trim() do
      "" -> {:error, "#{key} is required"}
      value -> {:ok, value}
    end
  end

  defp optional_text(args, key) do
    case args |> fetch(key) |> to_string() |> String.trim() do
      "" -> nil
      value -> value
    end
  end

  defp require_bool(args, key) do
    case fetch(args, key) do
      v when is_boolean(v) -> {:ok, v}
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      _ -> {:error, "#{key} must be true or false"}
    end
  end

  defp fetch(args, key) when is_map(args) do
    Map.get(args, key) || Map.get(args, Atom.to_string(key))
  end

  defp clamp_int(nil, default, _min, _max), do: default
  defp clamp_int(n, _default, min, max) when is_integer(n), do: n |> max(min) |> min(max)

  defp clamp_int(n, default, min, max) when is_binary(n) do
    case Integer.parse(n) do
      {i, ""} -> clamp_int(i, default, min, max)
      _ -> default
    end
  end

  defp clamp_int(_, default, _, _), do: default

  defp coerce_policy(key, value)
       when key in ["registration_open", "tunnel_block_meshcore_public"] do
    case value do
      v when is_boolean(v) -> v
      "true" -> true
      "false" -> false
      1 -> true
      0 -> false
      _ -> false
    end
  end

  defp coerce_policy(key, value)
       when key in ["announce_min_interval_sec", "nostr_publish_budget_per_hour"] do
    clamp_int(value, 0, 0, 1_000_000)
  end

  defp coerce_policy(_key, value) when is_list(value), do: Enum.map(value, &to_string/1)
  defp coerce_policy(_key, value) when is_binary(value), do: value
  defp coerce_policy(_key, value), do: value

  defp format_error(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> inspect()
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(reason), do: inspect(reason)

  defp safe_health(fun) do
    fun.()
  catch
    :exit, _ -> []
  end
end
