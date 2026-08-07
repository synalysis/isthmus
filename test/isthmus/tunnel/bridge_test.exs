defmodule Isthmus.Tunnel.BridgeTest do
  use Isthmus.DataCase, async: false

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
end
