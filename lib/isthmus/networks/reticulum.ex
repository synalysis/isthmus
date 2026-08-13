defmodule Isthmus.Networks.Reticulum do
  @moduledoc "Reticulum adapter (Python RNS/LXMF sidecar)."
  @behaviour Isthmus.NetworkAdapter

  require Logger

  alias Isthmus.Announce.Governor
  alias Isthmus.Announce.Sightings
  alias Isthmus.Networks.MeshCore.Discover
  alias Isthmus.Networks.Reticulum.ConfigFile
  alias Isthmus.Networks.Reticulum.InterfaceSocket
  alias Isthmus.Networks.Reticulum.Sidecar

  @impl true
  def network_id, do: :reticulum

  @impl true
  def capabilities, do: MapSet.new([:dm, :identity, :raw_tunnel, :announce])

  @impl true
  def parse_identity_ref(input) when is_binary(input) do
    cleaned = String.trim(input) |> String.downcase()

    cond do
      String.match?(cleaned, ~r/^[0-9a-f]{32}$/) ->
        {:ok, cleaned, %{destination_hash: cleaned}}

      String.match?(cleaned, ~r/^rns:\/\/[0-9a-f]{32}/) ->
        hash = cleaned |> String.trim_leading("rns://") |> String.slice(0, 32)
        {:ok, hash, %{destination_hash: hash}}

      true ->
        {:error, :invalid_reticulum_destination}
    end
  end

  @impl true
  def generate_proxy_identity(opts) do
    display_name = Map.get(opts, :name, "Isthmus")

    case Sidecar.create_identity(%{}) do
      {:ok, result} ->
        dest = result["destination_hash"]
        private_key_hex = result["private_key_hex"]
        public_key_hex = result["public_key_hex"]
        identity_hash = result["identity_hash"]

        _ =
          if private_key_hex && result["stub"] != true do
            Sidecar.register_identity(%{
              "private_key_hex" => private_key_hex,
              "display_name" => display_name
            })
          end

        # Announce asynchronously — avoids blocking registration / SQL sandbox owners.
        if dest && result["stub"] != true do
          Task.start(fn -> soft_announce(dest) end)
        end

        {:ok,
         %{
           identity_ref: dest,
           public_material: %{
             destination_hash: dest,
             identity_hash: identity_hash,
             public_key_hex: public_key_hex,
             app: "lxmf.delivery",
             stub: result["stub"] == true
           },
           private_material: %{
             private_key_hex: private_key_hex,
             public_key_hex: public_key_hex,
             identity_hash: identity_hash,
             destination_hash: dest
           },
           presentations: identity_presentations(dest, %{destination_hash: dest})
         }}

      {:error, reason} ->
        # Offline / stub fallback so self-service registration still works.
        fallback_identity(display_name, reason)
    end
  catch
    :exit, _ -> fallback_identity(Map.get(opts, :name, "Isthmus"), :sidecar_down)
  end

  @impl true
  def identity_presentations(ref, material) do
    dest = material[:destination_hash] || material["destination_hash"] || ref

    [
      %{
        format_id: "lxmf_destination",
        label: "LXMF destination",
        uri_or_text: dest,
        qr_payload: dest,
        app_hints: ["Sideband", "NomadNet", "MeshChat", "MeshChatX"]
      }
    ]
  end

  @impl true
  def health do
    sidecar =
      try do
        Sidecar.health()
      catch
        :exit, _ -> %{status: :not_started}
      end

    Map.merge(%{network: :reticulum, detail: "Python RNS/LXMF sidecar"}, sidecar)
  end

  @doc """
  Our own `isthmus.tunnel` destination hash (addressed tunnel mode), or `nil`.

  Peers paste this as the `peer_ref` on their tunnel to reach us point-to-point
  instead of over the broadcast path.
  """
  def tunnel_destination_hash do
    with true <- addressed_enabled?(),
         %{meta: meta} <- safe_health(),
         hash when is_binary(hash) and hash != "" <-
           meta["tunnel_destination_hash"] || meta[:tunnel_destination_hash] do
      hash
    else
      _ -> nil
    end
  end

  defp safe_health do
    Sidecar.health()
  catch
    :exit, _ -> %{}
  end

  @doc """
  Snapshot of RNS config, shared-instance role, and interface stats.

  Returns `{:ok, map}` or `{:error, reason}`.
  """
  def instance_status do
    try do
      case Sidecar.status() do
        {:ok, msg} -> {:ok, normalize_status(msg)}
        {:error, reason, _} -> {:error, reason}
        {:error, reason} -> {:error, reason}
      end
    catch
      :exit, _ -> {:error, :not_started}
    end
  end

  @doc "Path to Isthmus's own Reticulum config file."
  def config_path, do: ConfigFile.path()

  @doc "Interface blocks from Isthmus's config (comment-preserving source of truth)."
  def list_config_interfaces do
    ConfigFile.list_interfaces()
  end

  def add_config_interface(attrs) when is_map(attrs) do
    ConfigFile.add_interface(attrs)
  end

  def remove_config_interface(name) when is_binary(name) do
    ConfigFile.remove_interface(name)
  end

  def set_config_interface_enabled(name, enabled?)
      when is_binary(name) and is_boolean(enabled?) do
    ConfigFile.set_interface_enabled(name, enabled?)
  end

  def set_share_instance(enabled?) when is_boolean(enabled?) do
    ConfigFile.set_share_instance(enabled?)
  end

  def share_instance?, do: ConfigFile.share_instance?()

  @doc "USB RNodes claimed by Discover (KISS detect), for the Reticulum config pane."
  def detected_rnodes do
    roles =
      try do
        Discover.roles()
      catch
        :exit, _ -> %{}
      end

    Enum.map(roles[:rnode_ports] || [], fn entry ->
      detail = entry[:detail] || %{}
      path = entry[:path]

      %{
        path: path,
        label: rnode_label(detail, path),
        manufacturer: detail[:manufacturer],
        serial_number: detail[:serial_number],
        description: detail[:description]
      }
    end)
  end

  defp rnode_label(detail, path) do
    cond do
      is_binary(detail[:description]) and detail[:description] != "" ->
        detail[:description]

      is_binary(detail[:manufacturer]) and detail[:manufacturer] != "" ->
        detail[:manufacturer]

      is_binary(path) ->
        Path.basename(path)

      true ->
        "RNode"
    end
  end

  @doc "Request (or probe) an RNS path to a destination hash."
  def request_path(destination_hash) when is_binary(destination_hash) do
    try do
      case Sidecar.request_path(destination_hash) do
        {:ok, msg} -> {:ok, normalize_path_status(msg, destination_hash)}
        {:error, reason, _} -> {:error, reason}
        {:error, reason} -> {:error, reason}
      end
    catch
      :exit, _ -> {:error, :not_started}
    end
  end

  @doc "Whether RNS already recalls keys/path for a destination (no path request)."
  def path_status(destination_hash) when is_binary(destination_hash) do
    try do
      case Sidecar.path_status(destination_hash) do
        {:ok, msg} -> {:ok, normalize_path_status(msg, destination_hash)}
        {:error, reason, _} -> {:error, reason}
        {:error, reason} -> {:error, reason}
      end
    catch
      :exit, _ -> {:error, :not_started}
    end
  end

  defp normalize_path_status(msg, fallback_hash) when is_map(msg) do
    dest = msg["destination_hash"] || fallback_hash
    hops = path_int(msg["hops"])
    next_hop = path_hex(msg["next_hop"])
    interface = path_str(msg["interface"])

    %{
      destination_hash: dest,
      identity_known: msg["identity_known"] == true,
      path_known: msg["path_known"] == true,
      hops: hops,
      next_hop: next_hop,
      interface: interface,
      # RNS only stores next hop + hop count — not intermediate transport nodes.
      nodes: path_nodes(dest, next_hop, hops)
    }
  end

  defp path_int(n) when is_integer(n) and n >= 0, do: n
  defp path_int(_), do: nil

  defp path_hex(h) when is_binary(h) do
    trimmed = h |> String.trim() |> String.downcase()
    if trimmed != "" and String.match?(trimmed, ~r/^[0-9a-f]+$/), do: trimmed, else: nil
  end

  defp path_hex(_), do: nil

  defp path_str(s) when is_binary(s) do
    trimmed = String.trim(s)
    if trimmed == "", do: nil, else: trimmed
  end

  defp path_str(_), do: nil

  @doc false
  def path_route_nodes(dest, next_hop, hops), do: path_nodes(dest, next_hop, hops)

  defp path_nodes(_dest, _next_hop, nil), do: []
  defp path_nodes(dest, _next_hop, 0) when is_binary(dest), do: ["us", short_hash(dest)]

  defp path_nodes(dest, next_hop, 1) when is_binary(dest) do
    via = next_hop || dest

    if via == dest do
      ["us", short_hash(dest)]
    else
      ["us", short_hash(via), short_hash(dest)]
    end
  end

  defp path_nodes(dest, next_hop, hops) when is_integer(hops) and hops > 1 do
    via = if is_binary(next_hop), do: short_hash(next_hop), else: "?"
    # Ellipsis stands in for unknown intermediate transport nodes.
    ["us", via, "…", short_hash(dest)]
  end

  defp path_nodes(_, _, _), do: []

  defp short_hash(hash) when is_binary(hash) do
    if byte_size(hash) > 8, do: String.slice(hash, 0, 8), else: hash
  end

  @doc "Rewrite config is picked up by killing and respawning the Python sidecar."
  def apply_config do
    try do
      Sidecar.restart()
    catch
      :exit, _ -> {:error, :not_started}
    end
  end

  defp normalize_status(msg) when is_map(msg) do
    %{
      live: msg["live"] == true,
      configdir: msg["configdir"],
      storagepath: msg["storagepath"],
      instance_role: msg["instance_role"] || "unknown",
      instance: msg["instance"] || %{},
      config: msg["config"] || %{},
      traffic: msg["traffic"] || %{},
      interfaces: List.wrap(msg["interfaces"]),
      registered: List.wrap(msg["registered"]),
      registered_count: msg["registered_count"] || 0,
      stats_error: msg["stats_error"],
      stats_note: msg["stats_note"],
      interface_socket: interface_socket_health()
    }
  end

  defp interface_socket_health do
    try do
      Isthmus.Networks.Reticulum.InterfaceSocket.health()
    catch
      :exit, _ -> %{status: :not_started}
    end
  end

  @impl true
  def mtu(_opts), do: 500

  @impl true
  def estimated_bitrate(_opts), do: 1_000

  @impl true
  def send_raw(payload, opts) when is_binary(payload) do
    opts = Map.new(opts)

    # Addressed (opt-in): deliver point-to-point to the peer's tunnel destination
    # so only that peer receives the frame. Falls back to broadcast when disabled,
    # when we have no peer ref, or until the peer's identity + a path are known.
    case addressed_send(payload, opts) do
      :ok ->
        {:ok, :addressed}

      {:error, reason} ->
        Logger.debug("RNS addressed tunnel send failed (#{inspect(reason)}); trying broadcast")
        broadcast_send_mode(payload)

      :skip ->
        broadcast_send_mode(payload)
    end
  end

  defp broadcast_send_mode(payload) do
    case broadcast_raw(payload) do
      :ok -> {:ok, :broadcast}
      {:ok, _} -> {:ok, :broadcast}
      other -> other
    end
  end

  defp addressed_send(payload, opts) do
    with true <- addressed_enabled?(),
         ref when is_binary(ref) <- tunnel_peer_ref(opts) do
      case Sidecar.tunnel_send(ref, payload) do
        {:ok, _} -> :ok
        {:error, reason, _} -> {:error, reason}
        {:error, reason} -> {:error, reason}
        other -> {:error, other}
      end
    else
      # addressed disabled / no peer ref → caller broadcasts
      _ -> :skip
    end
  end

  # Prefer MeshChat IsthmusInterface clients; else inject into the sidecar RNS stack.
  defp broadcast_raw(payload) do
    case InterfaceSocket.send_frame(payload) do
      :ok -> :ok
      {:error, :not_connected} -> Sidecar.send_packet(payload)
      other -> other
    end
  end

  defp tunnel_peer_ref(opts) do
    ref = opts[:peer_ref] || opts["peer_ref"]

    case ref do
      r when is_binary(r) ->
        trimmed = String.trim(r)
        if trimmed == "", do: nil, else: String.downcase(trimmed)

      _ ->
        nil
    end
  end

  @doc """
  Whether point-to-point (addressed) tunnel delivery is active.

  Default is enabled; set `ISTHMUS_TUNNEL_ADDRESSED` to a falsey value
  (`0`/`false`/`no`/`off`) to force the legacy broadcast path.
  """
  def addressed_enabled? do
    normalized =
      (System.get_env("ISTHMUS_TUNNEL_ADDRESSED") || "1")
      |> String.trim()
      |> String.downcase()

    normalized not in ["0", "false", "no", "off"]
  end

  @impl true
  def send_message(dest, body, opts) when is_binary(dest) and is_binary(body) do
    attrs = %{
      "to" => dest,
      "body" => body,
      "from" => opts[:from] || opts["from"],
      "public_key_hex" => opts[:public_key_hex] || opts["public_key_hex"]
    }

    case Sidecar.send_lxmf(attrs) do
      {:ok, _} -> :ok
      {:error, reason, _} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def announce_or_advert(ref, opts \\ %{}) do
    opts = Map.new(opts)
    force? = opts[:force] in [true, "true", "1", 1] or opts["force"] in [true, "true", "1", 1]
    from_tunnel? = opts[:from_tunnel] in [true, "true", "1", 1]

    allowed =
      if force? do
        :ok
      else
        Governor.allow?(:announce, :reticulum, ref)
      end

    case allowed do
      :ok ->
        result =
          case Sidecar.announce(ref) do
            {:ok, _} = ok -> ok
            {:error, _, _} = err -> err
            {:error, _} = err -> err
          end

        if match?({:ok, _}, result) do
          _ =
            Sightings.record(%{
              network: "reticulum",
              direction: "out",
              identity_ref: ref,
              hops: 0,
              meta: %{source: "announce", from_tunnel: from_tunnel?}
            })

          unless from_tunnel? do
            Isthmus.Tunnel.Bridge.forward_announce("reticulum", ref, %{source: "announce"})
          end
        end

        case result do
          {:ok, _} -> :ok
          {:error, reason, _} -> {:error, reason}
          {:error, reason} -> {:error, reason}
        end

      {:drop, reason} ->
        {:error, {:governor, reason}}
    end
  end

  defp fallback_identity(display_name, reason) do
    seed = :crypto.strong_rand_bytes(32)
    dest = :crypto.hash(:sha256, seed) |> binary_part(0, 16) |> Base.encode16(case: :lower)

    {:ok,
     %{
       identity_ref: dest,
       public_material: %{
         destination_hash: dest,
         app: "lxmf.delivery",
         stub: true,
         fallback_reason: inspect(reason),
         name: display_name
       },
       private_material: %{
         private_key_hex: Base.encode16(seed, case: :lower),
         destination_hash: dest,
         stub: true
       },
       presentations: identity_presentations(dest, %{destination_hash: dest})
     }}
  end

  defp soft_announce(dest) do
    # Best-effort path announce after mint; rate limiting applies to explicit announce_or_advert/2.
    Sidecar.announce(dest)
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end
end
