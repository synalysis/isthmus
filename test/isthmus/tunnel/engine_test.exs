defmodule Isthmus.Tunnel.EngineTest do
  use Isthmus.DataCase, async: false

  alias Isthmus.Networks.Meshtastic.Transport
  alias Isthmus.Tunnel
  alias Isthmus.Tunnel.{Engine, Frame, Outbox}

  setup do
    Phoenix.PubSub.subscribe(Isthmus.PubSub, "tunnel:events")

    {:ok, peer} =
      Tunnel.create_peer(%{
        name: "E2E peer",
        peer_ref: "cc" <> String.duplicate("dd", 31),
        payload_network: "meshtastic",
        carrier_network: "meshtastic"
      })

    # Clear any leftover stub queue from other tests
    _ = Transport.drain_outbound(256)

    %{peer: peer}
  end

  test "drain sends ISTH frames over carrier and inbound reassembles", %{peer: peer} do
    payload = "island-hello-#{System.unique_integer([:positive])}"
    assert {:ok, _} = Tunnel.send_payload(peer, payload)

    send(Engine, :tick)
    _ = :sys.get_state(Engine)

    outbound = Transport.drain_outbound(16)
    assert outbound != []

    encoded = hd(outbound).payload
    assert {:ok, %Frame{flags: flags}, <<>>} = Frame.decode(encoded)
    assert Bitwise.band(flags, Frame.flag_data()) != 0

    # Deliver the same frames back into the Engine (remote side).
    Enum.each(outbound, fn %{payload: frame} ->
      Engine.handle_inbound_frame(frame)
    end)

    _ = :sys.get_state(Engine)

    assert_receive {:tunnel_delivered,
                    %{
                      tunnel_id: tunnel_id,
                      payload_network: "meshtastic",
                      bytes: bytes
                    }},
                   1_000

    assert tunnel_id == peer.tunnel_id
    assert bytes == byte_size(payload)

    # Injected into Meshtastic transport as payload (from_tunnel).
    injected = Transport.drain_outbound(16)
    assert Enum.any?(injected, &(&1.payload == payload))
  end

  test "control announce frame is ingested and acked", %{peer: peer} do
    tid = Frame.tunnel_id_from_string(peer.tunnel_id)

    control =
      Frame.control_frame(
        tid,
        42,
        Jason.encode!(%{
          "v" => 1,
          "op" => "announce",
          "network" => "meshtastic",
          "ref" => "deadbeef",
          "meta" => %{}
        })
      )

    Engine.handle_inbound_frame(Frame.encode(control))
    _ = :sys.get_state(Engine)

    assert_receive {:tunnel_control,
                    %{
                      tunnel_id: tunnel_id,
                      op: "announce",
                      network: "meshtastic",
                      ref: "deadbeef"
                    }},
                   1_000

    assert tunnel_id == peer.tunnel_id
  end

  test "outbox uses msg.payload (not the struct) when draining", %{peer: peer} do
    assert {:ok, msg} = Tunnel.send_payload(peer, "payload-bytes")
    assert is_binary(msg.payload)

    send(Engine, :tick)
    _ = :sys.get_state(Engine)

    refreshed = Outbox.get!(msg.id)
    assert refreshed.status in ["inflight", "acked", "pending"]
  end
end
