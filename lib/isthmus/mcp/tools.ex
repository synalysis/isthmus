defmodule Isthmus.MCP.Tools do
  @moduledoc false

  import Isthmus.MCP.Args

  alias Isthmus.Accounts
  alias Isthmus.Announce.Governor
  alias Isthmus.Announce.Sightings
  alias Isthmus.Audit
  alias Isthmus.Gateway
  alias Isthmus.Gateway.Message
  alias Isthmus.Gateway.Translator
  alias Isthmus.Messages
  alias Isthmus.Networks.Agent.Settings
  alias Isthmus.Networks.BLERemembered
  alias Isthmus.Networks.Health
  alias Isthmus.Networks.MeshCore.BLESidecar
  alias Isthmus.Networks.MeshCore.Companion, as: MeshCoreCompanion
  alias Isthmus.Networks.MeshCore.Supervisor, as: MeshCoreSupervisor
  alias Isthmus.Networks.Meshtastic.Companion, as: MeshtasticCompanion
  alias Isthmus.Networks.Meshtastic.Supervisor, as: MeshtasticSupervisor
  alias Isthmus.Policy
  alias Isthmus.Registrations
  alias Isthmus.Relays
  alias Isthmus.Topology
  alias Isthmus.Tunnel

  @type args :: map()
  @type result :: {:ok, map()} | {:error, String.t()}

  @writable_policy ~w(
    registration_open
    announce_min_interval_sec
    nostr_publish_budget_per_hour
    gateway_allow_directions
    gateway_deny_directions
    tunnel_block_meshcore_public
  )

  @spec health(args()) :: result()
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

  @spec list_groups(args()) :: result()
  def list_groups(_args \\ %{}) do
    groups =
      Registrations.list_all()
      |> Enum.map(&dump_group/1)

    {:ok, %{groups: groups}}
  end

  @spec get_group(args()) :: result()
  def get_group(args) do
    with {:ok, group} <- resolve_group(fetch(args, :group)) do
      {:ok, dump_group(group)}
    end
  end

  @spec create_group(args()) :: result()
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

  @spec attach_member(args()) :: result()
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

  @spec detach_member(args()) :: result()
  def detach_member(args) do
    with {:ok, group} <- resolve_group(fetch(args, :group)),
         {:ok, identity} <- require_text(args, :identity) do
      network = optional_text(args, :network)

      leg =
        Enum.find(group.legs, fn leg ->
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

  @spec inject_message(args()) :: result()
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

  @spec announce_group(args()) :: result()
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

  @spec mint_proxy(args()) :: result()
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

  @spec set_group_store_messages(args()) :: result()
  def set_group_store_messages(args) do
    with {:ok, group} <- resolve_group(fetch(args, :group)),
         {:ok, enabled} <- require_bool(args, :enabled) do
      case Registrations.set_store_messages(group, enabled) do
        {:ok, group} -> {:ok, dump_group(group)}
        {:error, reason} -> {:error, format_error(reason)}
      end
    end
  end

  @spec revoke_group(args()) :: result()
  def revoke_group(args) do
    with {:ok, group} <- resolve_group(fetch(args, :group)) do
      case Registrations.revoke(group) do
        {:ok, group} -> {:ok, dump_group(group)}
        {:error, reason} -> {:error, format_error(reason)}
      end
    end
  end

  @spec list_adverts(args()) :: result()
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

  @spec list_messages(args()) :: result()
  def list_messages(args) do
    limit = clamp_int(fetch(args, :limit), 50, 1, 200)
    network = optional_text(args, :network)
    kind = optional_text(args, :kind)

    opts =
      []
      |> then(fn opts -> if network, do: Keyword.put(opts, :networks, [network]), else: opts end)
      |> then(fn opts -> if kind, do: Keyword.put(opts, :kinds, [kind]), else: opts end)
      |> Keyword.put(:per_network, true)

    rows =
      Messages.list_recent(limit, opts)
      |> Enum.map(fn m ->
        %{
          id: m.id,
          at: m.seen_at,
          kind: m.kind,
          network: m.network,
          channel: m.channel_name,
          sender: m.sender_name || m.from_ref,
          body: m.body
        }
      end)

    {:ok, %{messages: rows}}
  end

  @spec list_tunnels(args()) :: result()
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

  @spec create_tunnel(args()) :: result()
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

  @spec set_tunnel_enabled(args()) :: result()
  def set_tunnel_enabled(args) do
    with {:ok, peer} <- resolve_tunnel(fetch(args, :tunnel)),
         {:ok, enabled} <- require_bool(args, :enabled) do
      case Tunnel.update_peer(peer, %{enabled: enabled}) do
        {:ok, peer} -> {:ok, dump_tunnel(peer)}
        {:error, reason} -> {:error, format_error(reason)}
      end
    end
  end

  @spec list_relays(args()) :: result()
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

  @spec create_relay(args()) :: result()
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

  @spec list_timeline(args()) :: result()
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

  @spec gateway_log(args()) :: result()
  def gateway_log(args) do
    limit = clamp_int(fetch(args, :limit), 30, 1, 100)

    {:ok, %{log: Gateway.list_forward_log(limit)}}
  end

  @spec governor_drops(args()) :: result()
  def governor_drops(_args \\ %{}) do
    {:ok, %{drops: Governor.drops_summary(20), stats: Governor.stats()}}
  end

  @spec get_policy(args()) :: result()
  def get_policy(_args \\ %{}) do
    {:ok, %{settings: Policy.all_settings(), directions: Policy.direction_keys()}}
  end

  @spec get_acp(args()) :: result()
  def get_acp(_args \\ %{}) do
    settings = Settings.current()
    health = safe_agent_health()

    {:ok,
     %{
       enabled: settings.enabled,
       command: settings.command,
       cwd: settings.cwd,
       preset: settings.preset,
       source: settings.source,
       status: health[:status],
       last_error: health[:last_error]
     }}
  end

  @spec set_acp(args()) :: result()
  def set_acp(args) do
    params = %{
      "enabled" => fetch(args, :enabled),
      "command" => optional_text(args, :command) || Settings.current().command,
      "cwd" => optional_text(args, :cwd) || Settings.current().cwd || "",
      "preset" => optional_text(args, :preset) || "custom"
    }

    params =
      if is_nil(fetch(args, :enabled)) do
        Map.put(params, "enabled", Settings.current().enabled)
      else
        params
      end

    case Settings.apply(params) do
      {:ok, health} ->
        {:ok,
         %{
           ok: true,
           status: health[:status] || health["status"],
           command: Settings.current().command,
           last_error: health[:last_error] || health["last_error"]
         }}

      {:error, :blank_command} ->
        {:error, "command is required when enabled"}
    end
  end

  @spec set_policy(args()) :: result()
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

  @spec list_radios(args()) :: result()
  def list_radios(_args \\ %{}) do
    {:ok,
     %{
       meshcore: safe_health(&MeshCoreCompanion.list_health/0),
       meshtastic: safe_health(&MeshtasticCompanion.list_health/0)
     }}
  end

  @spec bluetooth_status(args()) :: result()
  def bluetooth_status(_args \\ %{}) do
    adapter =
      case BLESidecar.adapter_status() do
        {:ok, msg} -> dump_adapter(msg)
        {:error, reason} -> %{error: format_error(reason)}
      end

    {:ok,
     %{
       sidecar: BLESidecar.health(),
       adapter: adapter,
       remembered: %{
         meshtastic: BLERemembered.list(:meshtastic),
         meshcore: BLERemembered.list(:meshcore)
       },
       radios: %{
         meshtastic: ble_radios(safe_health(&MeshtasticCompanion.list_health/0)),
         meshcore: ble_radios(safe_health(&MeshCoreCompanion.list_health/0))
       }
     }}
  end

  @spec scan_bluetooth(args()) :: result()
  def scan_bluetooth(args) do
    timeout = clamp_int(fetch(args, :timeout_ms), 5_000, 500, 15_000)

    case BLESidecar.scan(timeout) do
      {:ok, devices} ->
        {:ok,
         %{
           devices:
             Enum.map(devices, fn d ->
               %{
                 address: d.address,
                 name: d.name,
                 rssi: d.rssi,
                 kind: d.kind
               }
             end)
         }}

      {:error, reason} ->
        {:error, format_error(reason)}
    end
  end

  @spec connect_bluetooth(args()) :: result()
  def connect_bluetooth(args) do
    with {:ok, network} <- require_ble_network(args),
         {:ok, address} <- require_text(args, :address) do
      pin = optional_text(args, :pin)
      name = optional_text(args, :name)
      wait_ms = clamp_int(fetch(args, :wait_ms), 0, 0, 15_000)

      result =
        case network do
          :meshtastic -> MeshtasticSupervisor.start_ble(address, pin, name: name)
          :meshcore -> MeshCoreSupervisor.start_ble(address, pin)
        end

      case result do
        :ok ->
          radio = maybe_await_ble(network, address, wait_ms)

          {:ok,
           %{
             ok: true,
             network: network,
             address: norm_ble_addr(address),
             radio: dump_radio(radio)
           }}

        {:error, reason} ->
          {:error, format_error(reason)}
      end
    end
  end

  @spec disconnect_bluetooth(args()) :: result()
  def disconnect_bluetooth(args) do
    with {:ok, network} <- require_ble_network(args),
         {:ok, address} <- require_text(args, :address) do
      case network do
        :meshtastic -> MeshtasticSupervisor.stop_ble(address)
        :meshcore -> MeshCoreSupervisor.stop_ble(address)
      end

      {:ok, %{ok: true, network: network, address: norm_ble_addr(address)}}
    end
  end

  @spec set_meshtastic_time(args()) :: result()
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

  @spec set_meshtastic_settings(args()) :: result()
  def set_meshtastic_settings(args) do
    port = optional_text(args, :port)

    device =
      case optional_text(args, :buzzer_mode) do
        nil -> nil
        mode -> %{"buzzer_mode" => mode}
      end

    params =
      %{}
      |> then(fn p -> if device, do: Map.put(p, "device", device), else: p end)

    if params == %{} do
      {:error, "pass buzzer_mode (or another settings section)"}
    else
      case MeshtasticCompanion.set_settings(params, port) do
        {:ok, applied} ->
          {:ok,
           %{
             ok: true,
             buzzer_mode: get_in(applied, [:device, :buzzer_mode]),
             region: get_in(applied, [:lora, :region])
           }}

        {:error, reason} ->
          {:error, format_error(reason)}
      end
    end
  end

  @spec topology(args()) :: result()
  def topology(_args \\ %{}) do
    {:ok, Topology.build(:all)}
  end

  @spec list_admins(args()) :: result()
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
      store_messages: group.store_messages == true,
      members:
        Enum.map(group.legs, fn leg ->
          %{
            id: leg.id,
            network: leg.network,
            role: leg.role,
            identity: leg.identity_ref
          }
        end),
      channels:
        Enum.map(group.radio_channels, fn ch ->
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

  defp require_ble_network(args) do
    case args |> fetch(:network) |> to_string() |> String.downcase() |> String.trim() do
      "meshtastic" -> {:ok, :meshtastic}
      "meshcore" -> {:ok, :meshcore}
      "" -> {:error, "network is required (meshtastic or meshcore)"}
      other -> {:error, "unknown network: #{other}"}
    end
  end

  defp maybe_await_ble(_network, _address, wait_ms) when wait_ms <= 0, do: nil

  defp maybe_await_ble(network, address, wait_ms) do
    await_ble(network, address, System.monotonic_time(:millisecond) + wait_ms)
  end

  defp await_ble(network, address, deadline) do
    health = find_ble_health(network, address)
    status = health && (health[:status] || health["status"])

    cond do
      status in [:online, "online"] ->
        health

      System.monotonic_time(:millisecond) >= deadline ->
        health

      true ->
        Process.sleep(400)
        await_ble(network, address, deadline)
    end
  end

  defp find_ble_health(network, address) do
    want = norm_ble_addr(address)

    healths =
      case network do
        :meshtastic -> safe_health(&MeshtasticCompanion.list_health/0)
        :meshcore -> safe_health(&MeshCoreCompanion.list_health/0)
      end

    Enum.find(healths, fn health ->
      addr = health[:ble_address] || health["ble_address"]
      is_binary(addr) and norm_ble_addr(addr) == want
    end)
  end

  defp ble_radios(healths) when is_list(healths) do
    healths
    |> Enum.filter(fn health ->
      (health[:transport] || health["transport"]) in [:ble, "ble"] or
        is_binary(health[:ble_address] || health["ble_address"])
    end)
    |> Enum.map(&dump_radio/1)
  end

  defp ble_radios(_), do: []

  defp dump_radio(nil), do: nil

  defp dump_radio(health) when is_map(health) do
    %{
      status: health[:status] || health["status"],
      last_error: health[:last_error] || health["last_error"],
      ble_address: health[:ble_address] || health["ble_address"],
      port: health[:port] || health["port"],
      name: health[:name] || health["name"] || health[:self_name] || health["self_name"]
    }
  end

  defp dump_adapter(msg) when is_map(msg) do
    %{
      discovering: Map.get(msg, "discovering", Map.get(msg, :discovering)),
      clients: msg["clients"] || msg[:clients] || [],
      connecting: msg["connecting"] || msg[:connecting] || [],
      devices: msg["devices"] || msg[:devices] || []
    }
  end

  defp norm_ble_addr(address) when is_binary(address) do
    address
    |> String.trim()
    |> then(fn
      "ble:" <> rest -> rest
      "BLE:" <> rest -> rest
      other -> other
    end)
    |> String.upcase()
  end

  defp norm_ble_addr(_), do: ""

  defp safe_health(fun) do
    fun.()
  catch
    :exit, _ -> []
  end

  defp safe_agent_health do
    Isthmus.Networks.Agent.health()
  catch
    :exit, _ -> %{status: :not_started}
  end
end
