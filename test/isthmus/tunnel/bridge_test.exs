defmodule Isthmus.Tunnel.BridgeTest do
  use Isthmus.DataCase, async: false

  alias Isthmus.Networks.MeshCore.Packet
  alias Isthmus.Tunnel
  alias Isthmus.Tunnel.{Bridge, Outbox}

  setup do
    {:ok, peer} =
      Tunnel.create_peer(%{
        name: "Bridge peer",
        peer_ref: "aa" <> String.duplicate("bb", 31),
        payload_network: "reticulum",
        carrier_network: "meshtastic"
      })

    %{peer: peer}
  end

  test "forward_packet enqueues for matching payload peers", %{peer: peer} do
    packet = :crypto.strong_rand_bytes(32)
    assert :ok = Bridge.forward_packet("reticulum", packet, %{source: "test"})

    due = Outbox.due(10)
    assert Enum.any?(due, &(&1.channel == "tunnel:#{peer.tunnel_id}" and &1.payload == packet))
  end

  test "forward_packet skips from_tunnel and does not enqueue", %{peer: _peer} do
    before = length(Outbox.due(50))
    assert :ok = Bridge.forward_packet("reticulum", "loop", %{from_tunnel: true})
    assert length(Outbox.due(50)) == before
  end

  test "MeshCore dedup is path-insensitive so cyclic-tunnel re-floods collapse" do
    {:ok, mc} =
      Tunnel.create_peer(%{
        name: "MeshCore peer",
        peer_ref: "cc" <> String.duplicate("dd", 31),
        payload_network: "meshcore",
        carrier_network: "meshtastic"
      })

    payload = :crypto.strong_rand_bytes(24)

    flood0 =
      Packet.build(Packet.route_flood(), Packet.type_advert(), 0, <<>>, payload)
      |> Packet.encode()

    # Same payload re-flooded with an extra bridge hash appended (as arrives via
    # a second tunnel in an A–B–C triangle, or as the local repeater's echo).
    reflood =
      Packet.build(
        Packet.route_flood(),
        Packet.type_advert(),
        Packet.encode_path_len(1),
        <<0xAB>>,
        payload
      )
      |> Packet.encode()

    assert :ok = Bridge.forward_packet("meshcore", flood0, %{source: "island"})
    assert :ok = Bridge.forward_packet("meshcore", reflood, %{source: "island"})

    due = Outbox.due(50) |> Enum.filter(&(&1.channel == "tunnel:#{mc.tunnel_id}"))
    assert Enum.any?(due, &(&1.payload == flood0))
    refute Enum.any?(due, &(&1.payload == reflood))
  end

  test "forward_packet applies MeshCore channel_filter per peer" do
    alias Isthmus.Networks.MeshCore.Channel

    {:ok, mc} =
      Tunnel.create_peer(%{
        name: "Channel filter peer",
        peer_ref: "11" <> String.duplicate("22", 31),
        payload_network: "meshcore",
        carrier_network: "meshtastic"
      })

    public =
      Packet.build(
        Packet.route_flood(),
        Channel.type_grp_txt(),
        0,
        <<>>,
        <<Channel.public_channel_hash(), 0, 0>> <> :crypto.strong_rand_bytes(16)
      )
      |> Packet.encode()

    private =
      Packet.build(
        Packet.route_flood(),
        Channel.type_grp_txt(),
        0,
        <<>>,
        <<0x42, 0, 0>> <> :crypto.strong_rand_bytes(16)
      )
      |> Packet.encode()

    # Default "public" — only well-known Public blocked
    assert :ok = Bridge.forward_packet("meshcore", public, %{source: "bridge"})
    assert :ok = Bridge.forward_packet("meshcore", private, %{source: "bridge"})
    due = Outbox.due(50) |> Enum.filter(&(&1.channel == "tunnel:#{mc.tunnel_id}"))
    refute Enum.any?(due, &(&1.payload == public))
    assert Enum.any?(due, &(&1.payload == private))

    # "all" — both blocked
    assert {:ok, _} = Tunnel.update_peer(mc, %{channel_filter: "all"})

    private2 =
      Packet.build(
        Packet.route_flood(),
        Channel.type_grp_txt(),
        0,
        <<>>,
        <<0x43, 0, 0>> <> :crypto.strong_rand_bytes(16)
      )
      |> Packet.encode()

    assert :ok = Bridge.forward_packet("meshcore", private2, %{source: "bridge"})
    due = Outbox.due(50) |> Enum.filter(&(&1.channel == "tunnel:#{mc.tunnel_id}"))
    refute Enum.any?(due, &(&1.payload == private2))

    # "none" — Public allowed
    assert {:ok, _} = Tunnel.update_peer(mc, %{channel_filter: "none"})
    assert :ok = Bridge.forward_packet("meshcore", public, %{source: "bridge"})
    due = Outbox.due(50) |> Enum.filter(&(&1.channel == "tunnel:#{mc.tunnel_id}"))
    assert Enum.any?(due, &(&1.payload == public))
  end

  test "mark_forwarded suppresses the injected packet's echo across a bridge hop" do
    {:ok, mc} =
      Tunnel.create_peer(%{
        name: "MeshCore echo peer",
        peer_ref: "ee" <> String.duplicate("ff", 31),
        payload_network: "meshcore",
        carrier_network: "meshtastic"
      })

    payload = :crypto.strong_rand_bytes(20)

    injected =
      Packet.build(Packet.route_flood(), Packet.type_advert(), 0, <<>>, payload)
      |> Packet.encode()

    echo =
      Packet.build(
        Packet.route_flood(),
        Packet.type_advert(),
        Packet.encode_path_len(1),
        <<0x42>>,
        payload
      )
      |> Packet.encode()

    assert :ok = Bridge.mark_forwarded(injected)
    assert :duplicate = Bridge.mark_forwarded(injected)
    assert :ok = Bridge.forward_packet("meshcore", echo, %{source: "bridge"})

    due = Outbox.due(50) |> Enum.filter(&(&1.channel == "tunnel:#{mc.tunnel_id}"))
    refute Enum.any?(due, &(&1.payload == echo))
  end

  test "forward_announce enqueues control outbox rows", %{peer: peer} do
    ref = String.duplicate("ab", 16)
    assert :ok = Bridge.forward_announce("reticulum", ref, %{source: "announce"})

    msg =
      Outbox.due(20)
      |> Enum.find(&(&1.channel == "tunnel:#{peer.tunnel_id}" and &1.meta["kind"] == "control"))

    assert msg
    assert {:ok, body} = Jason.decode(msg.payload)
    assert body["op"] == "announce"
    assert body["ref"] == ref
  end

  test "MeshCore flood advert from the bridge is recorded on the Adverts feed" do
    alias Isthmus.Announce.Sightings
    alias Isthmus.Networks.MeshCore.{Advert, Crypto}

    {:ok, _mc} =
      Tunnel.create_peer(%{
        name: "Advert peer",
        peer_ref: "11" <> String.duplicate("22", 31),
        payload_network: "meshcore",
        carrier_network: "meshtastic"
      })

    {pub, seed} = Crypto.generate_keypair()
    hex = Base.encode16(pub, case: :lower)
    packet = Advert.build_flood(seed, pub, "Phone Node")

    assert :ok = Bridge.forward_packet("meshcore", packet, %{source: "bridge"})

    sighting = Sightings.best_for("meshcore", hex)
    assert sighting
    assert sighting.meta["source"] == "bridge_advert"
    assert sighting.meta["name"] == "Phone Node"
    assert sighting.hops == 0
  end

  test "MeshCore flood advert records hop count from the packet path" do
    alias Isthmus.Announce.Sightings
    alias Isthmus.Networks.MeshCore.{Advert, Crypto, Packet}

    {:ok, _mc} =
      Tunnel.create_peer(%{
        name: "Advert hops peer",
        peer_ref: "33" <> String.duplicate("44", 31),
        payload_network: "meshcore",
        carrier_network: "meshtastic"
      })

    {pub, seed} = Crypto.generate_keypair()
    hex = Base.encode16(pub, case: :lower)
    {:ok, decoded} = Packet.decode(Advert.build_flood(seed, pub, "Relay Node"))

    packet =
      Packet.encode(%{
        decoded
        | path_len: Packet.encode_path_len(3),
          path: <<0x01, 0x02, 0x03>>
      })

    assert :ok = Bridge.forward_packet("meshcore", packet, %{source: "bridge"})
    assert %{hops: 3, meta: %{"name" => "Relay Node"}} = Sightings.best_for("meshcore", hex)
  end

  test "bridge echo does not re-label a tunnel advert via" do
    alias Isthmus.Announce.Inbound
    alias Isthmus.Announce.Sightings
    alias Isthmus.Networks.MeshCore.{Advert, Crypto}

    {pub, seed} = Crypto.generate_keypair()
    hex = Base.encode16(pub, case: :lower)
    packet = Advert.build_flood(seed, pub, "Tunnel First")

    assert :ok =
             Inbound.record("meshcore", hex, "Tunnel First", "tunnel_advert", %{
               peer: "Local Test"
             })

    assert :ok = Bridge.forward_packet("meshcore", packet, %{source: "bridge"})
    assert Sightings.best_for("meshcore", hex).meta["source"] == "tunnel_advert"
  end
end
