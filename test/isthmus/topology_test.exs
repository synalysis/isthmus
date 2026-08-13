defmodule Isthmus.TopologyTest do
  use Isthmus.DataCase, async: false

  alias Isthmus.Announce.Sightings
  alias Isthmus.Registrations
  alias Isthmus.Topology
  alias Isthmus.Tunnel

  test "network detail includes network on connected legs for display formatting" do
    owner = owner_hex()

    assert {:ok, _group} =
             Registrations.register_self(owner, %{
               display_name: "Npub View",
               created_by: "admin"
             })

    graph = Topology.build(:all)
    detail = Topology.detail(graph, "network:nostr")

    assert detail.kind == :network
    assert detail.legs != []
    assert Enum.all?(detail.legs, &(&1.network == "nostr"))
    assert Enum.all?(detail.legs, &(byte_size(&1.ref) == 64))
  end

  test "build(:all) emits group and network nodes plus leg edges" do
    owner = owner_hex()
    mc = String.duplicate("ab", 32)

    assert {:ok, group} =
             Registrations.register_meshcore_primary(owner, mc, %{
               display_name: "Radio One",
               created_by: "admin"
             })

    graph = Topology.build(:all)

    group_node = Enum.find(graph.nodes, &(&1.id == "group:#{group.id}"))
    assert group_node
    assert group_node.kind == :group

    network_ids = graph.nodes |> Enum.filter(&(&1.kind == :network)) |> Enum.map(& &1.id)
    assert "network:meshcore" in network_ids
    assert "network:nostr" in network_ids
    assert "network:reticulum" in network_ids

    # Every leg becomes an edge from the group to its network.
    leg_count = length(group.legs)
    edges = Enum.filter(graph.edges, &(&1.from == "group:#{group.id}"))
    assert length(edges) == leg_count
    assert Enum.all?(edges, &String.starts_with?(&1.to, "network:"))
  end

  test "leg roles are classified and external members are dashed" do
    owner = owner_hex()

    assert {:ok, group} =
             Registrations.create_bridge_group(owner, %{display_name: "Dash Bridge"})

    assert {:ok, group} =
             Registrations.attach_member(group, "reticulum", "6d105c6ddcf9f9225ecd9f428520ca72")

    graph = Topology.build(:all)
    member = Enum.find(group.legs, &(&1.role == "member"))
    edge = Enum.find(graph.edges, &(&1.id == "leg:#{member.id}"))

    assert edge.role == "member"
    assert edge.external?
    assert edge.dashed?
  end

  test "owner scope excludes other owners' groups" do
    owner_a = owner_hex()
    owner_b = owner_hex()

    assert {:ok, group_a} =
             Registrations.register_self(owner_a, %{display_name: "Mine"})

    assert {:ok, _group_b} =
             Registrations.register_self(owner_b, %{display_name: "Theirs"})

    graph = Topology.build({:owner, owner_a})
    group_ids = graph.nodes |> Enum.filter(&(&1.kind == :group)) |> Enum.map(& &1.id)

    assert group_ids == ["group:#{group_a.id}"]
  end

  test "detail/2 returns group and network payloads" do
    owner = owner_hex()

    assert {:ok, group} =
             Registrations.register_self(owner, %{display_name: "Detailed"})

    graph = Topology.build(:all)

    group_detail = Topology.detail(graph, "group:#{group.id}")
    assert group_detail.kind == :group
    assert group_detail.title == "Detailed"
    assert group_detail.legs != []

    net_detail = Topology.detail(graph, "network:nostr")
    assert net_detail.kind == :network
    assert net_detail.legs != []
  end

  test "build(:all) on empty database yields no nodes" do
    graph = Topology.build(:all)
    assert graph.nodes == []
    assert graph.edges == []
  end

  test "tunnel peers become tunnel nodes with payload/carrier edges" do
    {:ok, peer} =
      Tunnel.create_peer(%{
        name: "RNS over MC",
        peer_ref: "aa" <> String.duplicate("bb", 31),
        payload_network: "reticulum",
        carrier_network: "meshcore"
      })

    graph = Topology.build(:all)

    node = Enum.find(graph.nodes, &(&1.id == "tunnel:#{peer.tunnel_id}"))
    assert node
    assert node.kind == :tunnel
    assert node.meta.enabled

    # Network nodes exist even without any groups, because the tunnel references them.
    network_ids = graph.nodes |> Enum.filter(&(&1.kind == :network)) |> Enum.map(& &1.id)
    assert "network:reticulum" in network_ids
    assert "network:meshcore" in network_ids

    payload = Enum.find(graph.edges, &(&1.id == "tunnel:#{peer.tunnel_id}:payload"))
    carrier = Enum.find(graph.edges, &(&1.id == "tunnel:#{peer.tunnel_id}:carrier"))
    assert payload.to == "network:reticulum"
    assert carrier.to == "network:meshcore"
    assert graph.counts.tunnels == 1
  end

  test "disabled tunnel peers are flagged dashed" do
    {:ok, peer} =
      Tunnel.create_peer(%{
        name: "Off tunnel",
        peer_ref: "cc" <> String.duplicate("dd", 31),
        payload_network: "reticulum",
        carrier_network: "nostr",
        enabled: false
      })

    graph = Topology.build(:all)
    node = Enum.find(graph.nodes, &(&1.id == "tunnel:#{peer.tunnel_id}"))
    refute node.meta.enabled

    detail = Topology.detail(graph, node.id)
    assert detail.kind == :tunnel
    refute detail.enabled
  end

  test "tunnels can be excluded via opts" do
    {:ok, _peer} =
      Tunnel.create_peer(%{
        name: "Hidden",
        peer_ref: "ee" <> String.duplicate("ff", 31),
        payload_network: "reticulum",
        carrier_network: "meshcore"
      })

    graph = Topology.build(:all, tunnels: false)
    assert graph.counts.tunnels == 0
    refute Enum.any?(graph.nodes, &(&1.kind == :tunnel))
  end

  test "owner scope only includes tunnels touching the owner's networks" do
    owner = owner_hex()

    assert {:ok, _group} =
             Registrations.register_self(owner, %{display_name: "OwnerNet"})

    # register_self mints nostr/reticulum/meshcore legs; a meshtastic-only tunnel is irrelevant.
    {:ok, _relevant} =
      Tunnel.create_peer(%{
        name: "Relevant",
        peer_ref: "11" <> String.duplicate("22", 31),
        payload_network: "reticulum",
        carrier_network: "meshcore"
      })

    {:ok, _irrelevant} =
      Tunnel.create_peer(%{
        name: "Irrelevant",
        peer_ref: "33" <> String.duplicate("44", 31),
        payload_network: "meshtastic",
        carrier_network: "meshtastic"
      })

    graph = Topology.build({:owner, owner})
    tunnel_labels = graph.nodes |> Enum.filter(&(&1.kind == :tunnel)) |> Enum.map(& &1.label)

    assert "Relevant" in tunnel_labels
    refute "Irrelevant" in tunnel_labels
  end

  test "a linked MeshCore channel slot draws an edge to the MeshCore node" do
    owner = owner_hex()

    assert {:ok, group} =
             Registrations.create_bridge_group(owner, %{display_name: "Slotted"})

    assert {:ok, group} =
             Registrations.link_meshcore_channel(group, 3, String.duplicate("ab", 16))

    graph = Topology.build(:all)

    edge = Enum.find(graph.edges, &channel_edge?(&1, group, "meshcore"))
    assert edge
    assert edge.type == :channel
    assert edge.from == "group:#{group.id}"
    assert edge.to == "network:meshcore"
    assert edge.channel_idx == 3
    assert edge.ref == "ch 3"

    assert Enum.any?(graph.nodes, &(&1.id == "network:meshcore"))
    assert graph.counts.channels == 1
    refute Enum.any?(graph.edges, &(&1.type == :leg and &1.id == edge.id))
  end

  test "a linked Meshtastic channel slot draws an edge to the Meshtastic node" do
    owner = owner_hex()

    assert {:ok, group} =
             Registrations.create_bridge_group(owner, %{display_name: "MT Slotted"})

    assert {:ok, group} =
             Registrations.link_meshtastic_channel(group, 2, String.duplicate("ab", 16))

    graph = Topology.build(:all)

    edge = Enum.find(graph.edges, &channel_edge?(&1, group, "meshtastic"))
    assert edge
    assert edge.type == :channel
    assert edge.from == "group:#{group.id}"
    assert edge.to == "network:meshtastic"
    assert edge.channel_idx == 2
    assert edge.ref == "ch 2"

    assert Enum.any?(graph.nodes, &(&1.id == "network:meshtastic"))
    assert graph.counts.channels >= 1
  end

  test "two Meshtastic radios on one group draw two channel edges" do
    owner = owner_hex()
    psk = String.duplicate("ab", 16)

    assert {:ok, group} =
             Registrations.create_bridge_group(owner, %{display_name: "Lobby"})

    assert {:ok, group} =
             Registrations.link_meshtastic_channel(group, 6, psk, device_id: "aabbccdd")

    assert {:ok, group} =
             Registrations.link_meshtastic_channel(group, 2, psk, device_id: "11223344")

    graph = Topology.build(:all)

    edges =
      graph.edges
      |> Enum.filter(&channel_edge?(&1, group, "meshtastic"))
      |> Enum.sort_by(& &1.channel_idx)

    assert Enum.map(edges, & &1.channel_idx) == [2, 6]
    assert Enum.map(edges, & &1.device_id) == ["11223344", "aabbccdd"]
    assert Enum.map(edges, & &1.ref) == ["ch 2 · 11223344", "ch 6 · aabbccdd"]
    assert length(Enum.uniq(Enum.map(edges, & &1.id))) == 2
    assert length(Enum.uniq(Enum.map(edges, & &1.offset))) == 2
    assert graph.counts.channels >= 2

    group_node = Enum.find(graph.nodes, &(&1.id == "group:#{group.id}"))
    assert group_node.meta.channel_caption == "MT 2, MT 6"

    detail = Topology.detail(graph, "group:#{group.id}")
    assert Enum.map(detail.channels, & &1.channel_idx) == [2, 6]
    assert Enum.all?(detail.channels, &(&1.network == "meshtastic"))
  end

  test "channel edge does not overlap the group's MeshCore leg edges" do
    owner = owner_hex()

    assert {:ok, group} =
             Registrations.create_bridge_group(owner, %{display_name: "Overlap"})

    assert {:ok, group} =
             Registrations.link_meshcore_channel(group, 5, String.duplicate("cd", 16))

    graph = Topology.build(:all)

    offsets =
      graph.edges
      |> Enum.filter(&(&1.from == "group:#{group.id}" and &1.to == "network:meshcore"))
      |> Enum.map(& &1.offset)

    assert offsets != []
    assert length(Enum.uniq(offsets)) == length(offsets)
  end

  test "groups without a channel slot produce no channel edges" do
    owner = owner_hex()
    assert {:ok, _group} = Registrations.register_self(owner, %{display_name: "NoSlot"})

    graph = Topology.build(:all)

    assert graph.counts.channels == 0
    refute Enum.any?(graph.edges, &(&1.type == :channel))
  end

  test "network nodes carry health severity metadata" do
    owner = owner_hex()
    assert {:ok, _group} = Registrations.register_self(owner, %{display_name: "HealthNet"})

    graph = Topology.build(:all)
    network_nodes = Enum.filter(graph.nodes, &(&1.kind == :network))

    assert network_nodes != []
    assert Enum.all?(network_nodes, &Map.has_key?(&1.meta, :severity))
  end

  test "recent tunnel sightings annotate the node and its edges" do
    {:ok, peer} =
      Tunnel.create_peer(%{
        name: "Watched",
        peer_ref: "55" <> String.duplicate("66", 31),
        payload_network: "reticulum",
        carrier_network: "meshcore"
      })

    {:ok, _} =
      Sightings.record(%{
        network: "meshcore",
        identity_ref: peer.peer_ref,
        tunnel_id: peer.tunnel_id,
        hops: 3,
        latency_ms: 120
      })

    graph = Topology.build(:all)

    node = Enum.find(graph.nodes, &(&1.id == "tunnel:#{peer.tunnel_id}"))
    assert node.meta.sighting
    assert node.meta.sighting.hops == 3

    detail = Topology.detail(graph, node.id)
    assert detail.sighting.latency_ms == 120

    payload = Enum.find(graph.edges, &(&1.id == "tunnel:#{peer.tunnel_id}:payload"))
    assert payload.recent?
  end

  test "path_by_leg annotates external reticulum leg edges" do
    owner = owner_hex()

    assert {:ok, group} =
             Registrations.create_bridge_group(owner, %{display_name: "PathBridge"})

    assert {:ok, group} =
             Registrations.attach_member(group, "reticulum", "6d105c6ddcf9f9225ecd9f428520ca72")

    member = Enum.find(group.legs, &(&1.role == "member"))

    graph = Topology.build(:all, path_by_leg: %{member.id => %{path_known: true}})
    edge = Enum.find(graph.edges, &(&1.id == "leg:#{member.id}"))

    assert edge.path_state == :known
  end

  test "health can be disabled via opts" do
    {:ok, _peer} =
      Tunnel.create_peer(%{
        name: "NoHealth",
        peer_ref: "77" <> String.duplicate("88", 31),
        payload_network: "reticulum",
        carrier_network: "meshcore"
      })

    graph = Topology.build(:all, health: false)
    network_nodes = Enum.filter(graph.nodes, &(&1.kind == :network))

    assert Enum.all?(network_nodes, &is_nil(&1.meta.severity))
  end

  describe "bridged islands" do
    test "a bridged network is flagged and called out in its detail" do
      {:ok, _peer} =
        Tunnel.create_peer(%{
          name: "Island",
          peer_ref: "aa" <> String.duplicate("b1", 31),
          payload_network: "meshcore",
          carrier_network: "reticulum"
        })

      graph = Topology.build(:all, bridged_networks: ["meshcore"])

      meshcore = Enum.find(graph.nodes, &(&1.kind == :network and &1.meta.network == "meshcore"))
      assert meshcore.meta.bridged? == true

      detail = Topology.detail(graph, meshcore.id)
      assert detail.bridged? == true
      assert detail.subtitle =~ "bridged island"
    end

    test "networks without a bridge are not flagged" do
      {:ok, _peer} =
        Tunnel.create_peer(%{
          name: "Plain",
          peer_ref: "cc" <> String.duplicate("b2", 31),
          payload_network: "meshcore",
          carrier_network: "reticulum"
        })

      graph = Topology.build(:all, bridged_networks: [])

      assert Enum.all?(
               Enum.filter(graph.nodes, &(&1.kind == :network)),
               &(&1.meta.bridged? == false)
             )
    end
  end

  defp owner_hex do
    {_seckey, pubkey} = Secp256k1.keypair(:xonly)
    Base.encode16(pubkey, case: :lower)
  end

  defp channel_edge?(edge, group, network) do
    edge.type == :channel and edge.from == "group:#{group.id}" and edge.network == network
  end
end
