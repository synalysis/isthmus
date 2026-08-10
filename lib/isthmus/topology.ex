defmodule Isthmus.Topology do
  @moduledoc """
  Builds a graph model of registration/bridge groups, the networks they touch,
  and the tunnels the bridge carries between networks.

  The output is layout-complete: every node carries `x`/`y` so the renderer can
  emit stable SVG without a client-side layout engine.

  Scopes:

    * `:all` — every group (admin whole-bridge map)
    * `{:owner, pubkey_hex}` — only groups owned by `pubkey_hex` (`/me`)
  """

  alias Isthmus.Announce.Sightings
  alias Isthmus.Networks.Health
  alias Isthmus.Registrations
  alias Isthmus.Registrations.{IdentityLeg, RegistrationGroup}
  alias Isthmus.Tunnel
  alias Isthmus.Tunnel.Peer

  @network_order ~w(reticulum meshcore nostr meshtastic)

  # Layout constants (SVG user units).
  @base_width 1000
  @tunnel_width 1220
  @margin_top 78
  @row_height 128
  @group_x 230
  @network_x 770
  @tunnel_x 1040
  @min_height 280

  @type node_t :: %{
          id: String.t(),
          kind: :group | :network | :tunnel,
          label: String.t(),
          x: number(),
          y: number(),
          meta: map()
        }

  @type edge_t :: %{
          id: String.t(),
          type: :leg | :channel | :tunnel,
          from: String.t(),
          to: String.t(),
          role: String.t(),
          network: String.t(),
          ref: String.t() | nil,
          external?: boolean(),
          dashed?: boolean(),
          offset: number()
        }

  @doc """
  Build the topology graph for the given scope.

  Options:

    * `:tunnels` — include tunnel peers (default `true`)
    * `:health` — decorate network nodes with `Networks.Health` severity and
      tunnel edges/nodes with recent sightings (default `true`)
    * `:path_by_leg` — map of `leg_id => path_status` used to annotate external
      Reticulum leg edges (default `%{}`)
  """
  def build(scope, opts \\ []) do
    groups = load_groups(scope)
    include_tunnels? = Keyword.get(opts, :tunnels, true)
    health? = Keyword.get(opts, :health, true)
    path_by_leg = Keyword.get(opts, :path_by_leg, %{})

    leg_networks = networks_from_groups(groups)
    channel_networks = networks_from_channels(groups)
    peers = if include_tunnels?, do: load_peers(scope, leg_networks ++ channel_networks), else: []
    tunnel_networks = networks_from_peers(peers)
    networks = order_networks(Enum.uniq(leg_networks ++ channel_networks ++ tunnel_networks))

    severity_by_network = if health?, do: severity_map(), else: %{}
    sighting_by_tunnel = if health?, do: sighting_map(peers), else: %{}

    bridged =
      Keyword.get(opts, :bridged_networks) || if(health?, do: bridged_networks(), else: [])

    group_nodes = group_nodes(groups)
    network_nodes = network_nodes(networks, severity_by_network, bridged)
    peer_nodes = peer_nodes(peers, sighting_by_tunnel)
    edges = group_edges(groups, path_by_leg) ++ tunnel_edges(peers, sighting_by_tunnel)

    width = if peers == [], do: @base_width, else: @tunnel_width

    %{
      scope: scope,
      width: width,
      height: canvas_height([length(group_nodes), length(network_nodes), length(peer_nodes)]),
      nodes: group_nodes ++ network_nodes ++ peer_nodes,
      edges: edges,
      legend: legend(),
      counts: %{
        groups: length(group_nodes),
        networks: length(network_nodes),
        legs: Enum.count(edges, &(&1.type == :leg)),
        channels: Enum.count(edges, &(&1.type == :channel)),
        tunnels: length(peer_nodes)
      }
    }
  end

  @doc "Find a node by its id."
  def node(%{nodes: nodes}, id) when is_binary(id) do
    Enum.find(nodes, &(&1.id == id))
  end

  def node(_graph, _id), do: nil

  @doc """
  Detail payload for a selected node id — used to render the side drawer.

  Returns `nil` when the node is not found.
  """
  def detail(%{nodes: nodes, edges: edges}, id) when is_binary(id) do
    case Enum.find(nodes, &(&1.id == id)) do
      nil -> nil
      %{kind: :group} = node -> group_detail(node, edges)
      %{kind: :network} = node -> network_detail(node, edges)
      %{kind: :tunnel} = node -> tunnel_detail(node)
    end
  end

  def detail(_graph, _id), do: nil

  # --- loading ----------------------------------------------------------------

  defp load_groups(:all) do
    Registrations.list_all()
    |> Enum.filter(&(&1.status != "revoked"))
  end

  defp load_groups({:owner, pubkey_hex}) when is_binary(pubkey_hex) do
    Registrations.get_for_owner(pubkey_hex)
  end

  defp load_groups(_), do: []

  defp load_peers(:all, _leg_networks), do: Tunnel.list_peers()

  defp load_peers({:owner, _hex}, leg_networks) do
    # Owner map shows only tunnels touching a network the owner actually uses.
    Tunnel.list_peers()
    |> Enum.filter(fn peer ->
      peer.payload_network in leg_networks or peer.carrier_network in leg_networks
    end)
  end

  defp load_peers(_, _), do: []

  # --- nodes ------------------------------------------------------------------

  defp group_nodes(groups) do
    groups
    |> Enum.with_index()
    |> Enum.map(fn {group, idx} ->
      %{
        id: group_id(group),
        kind: :group,
        label: group.display_name || "Group",
        x: @group_x,
        y: row_y(idx),
        meta: %{
          kind: group.kind || "registration",
          status: group.status,
          slug: Registrations.token_slug(group.display_name),
          channel_idx: group.meshcore_channel_idx,
          legs: Enum.map(group.legs, &leg_summary/1)
        }
      }
    end)
  end

  defp network_nodes(networks, severity_by_network, bridged) do
    networks
    |> Enum.with_index()
    |> Enum.map(fn {network, idx} ->
      %{
        id: network_id(network),
        kind: :network,
        label: network_label(network),
        x: @network_x,
        y: row_y(idx),
        meta: %{
          network: network,
          severity: Map.get(severity_by_network, network),
          bridged?: network in bridged
        }
      }
    end)
  end

  # --- edges ------------------------------------------------------------------

  # Leg and channel edges share one offset pass so a group's MeshCore slot line
  # doesn't land on top of its MeshCore identity legs.
  defp group_edges(groups, path_by_leg) do
    (leg_edges(groups, path_by_leg) ++ channel_edges(groups))
    |> apply_parallel_offsets()
  end

  defp leg_edges(groups, path_by_leg) do
    Enum.flat_map(groups, fn group ->
      Enum.map(group.legs, fn %IdentityLeg{} = leg ->
        external? = external?(leg)

        %{
          id: "leg:#{leg.id}",
          type: :leg,
          from: group_id(group),
          to: network_id(leg.network),
          role: leg.role,
          network: leg.network,
          ref: leg.identity_ref,
          external?: external?,
          dashed?: external?,
          path_state: path_state(leg, path_by_leg),
          channel_idx: nil,
          offset: 0
        }
      end)
    end)
  end

  # A group with a MeshCore channel slot bridges group chat on that slot even
  # when it holds no MeshCore identity leg, so it gets its own edge.
  defp channel_edges(groups) do
    groups
    |> Enum.filter(&(&1.meshcore_channel_idx != nil))
    |> Enum.map(fn group ->
      %{
        id: "channel:#{group.id}",
        type: :channel,
        from: group_id(group),
        to: network_id("meshcore"),
        role: "channel",
        network: "meshcore",
        ref: "ch #{group.meshcore_channel_idx}",
        external?: false,
        dashed?: false,
        path_state: nil,
        channel_idx: group.meshcore_channel_idx,
        offset: 0
      }
    end)
  end

  # Path state only applies to external Reticulum legs the bridge must reach.
  defp path_state(%IdentityLeg{network: "reticulum", role: role} = leg, path_by_leg)
       when role in ["primary", "member"] do
    case Map.get(path_by_leg, leg.id) do
      %{path_known: true} -> :known
      %{identity_known: true} -> :known
      %{error: _} -> :unavailable
      %{} -> :unknown
      _ -> nil
    end
  end

  defp path_state(_leg, _path_by_leg), do: nil

  defp peer_nodes(peers, sighting_by_tunnel) do
    peers
    |> Enum.with_index()
    |> Enum.map(fn {peer, idx} ->
      %{
        id: peer_id(peer),
        kind: :tunnel,
        label: peer.name || "tunnel",
        x: @tunnel_x,
        y: row_y(idx),
        meta: %{
          tunnel_id: peer.tunnel_id,
          enabled: peer.enabled,
          payload_network: peer.payload_network,
          carrier_network: peer.carrier_network,
          peer_ref: peer.peer_ref,
          seq: peer.next_seq,
          sighting: Map.get(sighting_by_tunnel, peer.tunnel_id)
        }
      }
    end)
  end

  defp tunnel_edges(peers, sighting_by_tunnel) do
    Enum.flat_map(peers, fn %Peer{} = peer ->
      recent? = Map.has_key?(sighting_by_tunnel, peer.tunnel_id)

      [
        %{
          id: "tunnel:#{peer.tunnel_id}:payload",
          type: :tunnel,
          leg: :payload,
          from: peer_id(peer),
          to: network_id(peer.payload_network),
          role: "payload",
          network: peer.payload_network,
          ref: peer.tunnel_id,
          external?: false,
          dashed?: not peer.enabled,
          recent?: recent?,
          offset: 0
        },
        %{
          id: "tunnel:#{peer.tunnel_id}:carrier",
          type: :tunnel,
          leg: :carrier,
          from: peer_id(peer),
          to: network_id(peer.carrier_network),
          role: "carrier",
          network: peer.carrier_network,
          ref: peer.tunnel_id,
          external?: false,
          dashed?: true,
          recent?: recent?,
          offset: 0
        }
      ]
    end)
  end

  # Spread edges that share the same from/to so parallel legs (e.g. bridge member
  # + proxy on the same network) don't render on top of each other.
  defp apply_parallel_offsets(edges) do
    edges
    |> Enum.group_by(&{&1.from, &1.to})
    |> Enum.flat_map(fn {_key, group_edges} ->
      count = length(group_edges)

      group_edges
      |> Enum.with_index()
      |> Enum.map(fn {edge, idx} ->
        %{edge | offset: (idx - (count - 1) / 2) * 16}
      end)
    end)
  end

  # --- detail -----------------------------------------------------------------

  defp group_detail(%{id: id, label: label, meta: meta}, _edges) do
    %{
      kind: :group,
      id: id,
      title: label,
      subtitle: "#{meta.kind} group",
      slug: meta.slug,
      status: meta.status,
      channel_idx: meta.channel_idx,
      legs: meta.legs
    }
  end

  defp network_detail(%{id: id, label: label, meta: meta}, edges) do
    connected =
      edges
      |> Enum.filter(&(&1.to == id and &1.type in [:leg, :channel]))
      |> Enum.map(fn edge ->
        %{role: edge.role, ref: edge.ref, external?: edge.external?}
      end)

    legs = Enum.count(edges, &(&1.to == id and &1.type == :leg))
    channels = Enum.count(edges, &(&1.to == id and &1.type == :channel))
    tunnels = Enum.count(edges, &(&1.to == id and &1.type == :tunnel))

    subtitle =
      ["#{legs} leg(s)"]
      |> maybe_append(channels > 0, "#{channels} channel slot(s)")
      |> maybe_append(tunnels > 0, "#{tunnels} tunnel edge(s)")
      |> maybe_append(meta[:bridged?] == true, "bridged island")
      |> Enum.join(" · ")

    %{
      kind: :network,
      id: id,
      title: label,
      subtitle: subtitle,
      network: meta.network,
      severity: meta.severity,
      bridged?: meta[:bridged?] == true,
      legs: connected
    }
  end

  defp maybe_append(parts, true, part), do: parts ++ [part]
  defp maybe_append(parts, false, _part), do: parts

  defp tunnel_detail(%{id: id, label: label, meta: meta}) do
    %{
      kind: :tunnel,
      id: id,
      title: label,
      subtitle: "#{meta.payload_network} over #{meta.carrier_network}",
      enabled: meta.enabled,
      tunnel_id: meta.tunnel_id,
      peer_ref: meta.peer_ref,
      seq: meta.seq,
      sighting: sighting_summary(meta.sighting),
      legs: []
    }
  end

  # --- helpers ----------------------------------------------------------------

  # A bridged network carries whole foreign packets rather than just our own
  # traffic, so it's worth calling out on the map.
  defp bridged_networks do
    if Isthmus.Networks.MeshCore.BridgeLink.health()[:status] == :online do
      ["meshcore"]
    else
      []
    end
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp severity_map do
    Health.report_all()
    |> Enum.reduce(%{}, fn report, acc ->
      case report do
        %{network: network, severity: severity} when not is_nil(network) ->
          Map.put(acc, to_string(network), severity)

        _ ->
          acc
      end
    end)
  end

  defp sighting_map(peers) do
    peers
    |> Enum.reduce(%{}, fn peer, acc ->
      case Sightings.latest_for_tunnel(peer.tunnel_id) do
        nil -> acc
        sighting -> Map.put(acc, peer.tunnel_id, sighting)
      end
    end)
  end

  defp sighting_summary(nil), do: nil

  defp sighting_summary(sighting) do
    %{
      hops: sighting.hops,
      latency_ms: sighting.latency_ms,
      seen_at: sighting.seen_at
    }
  end

  defp networks_from_groups(groups) do
    groups
    |> Enum.flat_map(& &1.legs)
    |> Enum.map(& &1.network)
    |> Enum.uniq()
  end

  defp networks_from_channels(groups) do
    if Enum.any?(groups, &(&1.meshcore_channel_idx != nil)), do: ["meshcore"], else: []
  end

  defp networks_from_peers(peers) do
    peers
    |> Enum.flat_map(&[&1.payload_network, &1.carrier_network])
    |> Enum.uniq()
  end

  defp order_networks(used) do
    @network_order
    |> Enum.filter(&(&1 in used))
    |> Kernel.++(Enum.reject(used, &(&1 in @network_order)))
  end

  defp leg_summary(%IdentityLeg{} = leg) do
    %{
      id: leg.id,
      network: leg.network,
      role: leg.role,
      ref: leg.identity_ref,
      external?: external?(leg)
    }
  end

  defp external?(%IdentityLeg{role: role}), do: role in ["primary", "member"]

  defp group_id(%RegistrationGroup{id: id}), do: "group:#{id}"
  defp network_id(network), do: "network:#{network}"
  defp peer_id(%Peer{tunnel_id: tid}), do: "tunnel:#{tid}"

  defp network_label("reticulum"), do: "Reticulum"
  defp network_label("meshcore"), do: "MeshCore"
  defp network_label("nostr"), do: "Nostr"
  defp network_label("meshtastic"), do: "Meshtastic"
  defp network_label(other), do: other |> to_string() |> String.capitalize()

  defp row_y(idx), do: @margin_top + idx * @row_height

  defp canvas_height(row_counts) when is_list(row_counts) do
    rows = Enum.max(row_counts)
    max(@min_height, @margin_top + rows * @row_height)
  end

  defp legend do
    [
      %{key: "primary", label: "Primary (owner identity)"},
      %{key: "member", label: "Member (attached peer)"},
      %{key: "proxy", label: "Proxy (Isthmus-owned)"},
      %{key: "channel", label: "MeshCore channel slot"},
      %{key: "payload", label: "Tunnel payload"},
      %{key: "carrier", label: "Tunnel carrier"}
    ]
  end
end
