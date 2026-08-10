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

  test "keepalive ping marks a tunnel reachable and records RTT", %{peer: peer} do
    _ = Transport.drain_outbound(256)

    prev = Application.get_env(:isthmus, :tunnel_ping_enabled, true)
    Application.put_env(:isthmus, :tunnel_ping_enabled, true)
    on_exit(fn -> Application.put_env(:isthmus, :tunnel_ping_enabled, prev) end)

    # 1. Trigger a ping sweep: the Engine sends a control "ping" over the carrier.
    send(Engine, :ping)
    _ = :sys.get_state(Engine)

    ping_frame =
      Transport.drain_outbound(16)
      |> find_frame(fn %Frame{flags: flags} = f ->
        Bitwise.band(flags, Frame.flag_control()) != 0 and control_op(f) == "ping"
      end)

    assert is_binary(ping_frame)

    # 2. Far side receives the ping and ACKs it.
    Engine.handle_inbound_frame(ping_frame)
    _ = :sys.get_state(Engine)

    ack_frame =
      Transport.drain_outbound(16)
      |> find_frame(fn %Frame{flags: flags} ->
        Bitwise.band(flags, Frame.flag_ack()) != 0
      end)

    assert is_binary(ack_frame)

    # 3. Sender receives the ACK and marks the tunnel reachable with an RTT.
    Engine.handle_inbound_frame(ack_frame)
    _ = :sys.get_state(Engine)

    assert_receive {:tunnel_ping, %{tunnel_id: tunnel_id, rtt_ms: rtt}}, 1_000
    assert tunnel_id == peer.tunnel_id
    assert is_integer(rtt) and rtt >= 0

    assert %{status: :reachable, rtt_ms: ^rtt, last_ping_mode: :addressed} =
             Map.get(Engine.health(), peer.tunnel_id)
  end

  test "inbound ping records last_inbound without marking outbound reachable", %{peer: peer} do
    tid = Frame.tunnel_id_from_string(peer.tunnel_id)

    remote_ping =
      Frame.control_frame(
        tid,
        99,
        Jason.encode!(%{"v" => 1, "op" => "ping", "ts" => System.system_time(:millisecond)})
      )

    Engine.handle_inbound_frame(Frame.encode(remote_ping))
    _ = :sys.get_state(Engine)

    health = Map.get(Engine.health(), peer.tunnel_id)

    assert health.last_inbound_kind == :ping
    assert is_integer(health.last_inbound_at)
    assert health.inbound_status == :fresh
    assert health.status != :reachable
    assert health.inbound_only? == true
  end

  test "health records last_ping_mode when send reports broadcast fallback", %{peer: peer} do
    prev = Application.get_env(:isthmus, :tunnel_ping_enabled, true)
    Application.put_env(:isthmus, :tunnel_ping_enabled, true)
    Application.put_env(:isthmus, :meshtastic_send_mode, :broadcast)

    on_exit(fn ->
      Application.put_env(:isthmus, :tunnel_ping_enabled, prev)
      Application.delete_env(:isthmus, :meshtastic_send_mode)
    end)

    send(Engine, :ping)
    _ = :sys.get_state(Engine)

    assert %{last_ping_mode: :broadcast, status: status} =
             Map.get(Engine.health(), peer.tunnel_id)

    assert status in [:unreachable, :unknown]
  end

  test "a meshcore payload is delivered through the bridge, not the companion" do
    {:ok, peer} =
      Tunnel.create_peer(%{
        name: "Island peer",
        peer_ref: "ee" <> String.duplicate("ff", 31),
        payload_network: "meshcore",
        carrier_network: "meshtastic"
      })

    payload = "raw-mesh-packet-#{System.unique_integer([:positive])}"

    peer.tunnel_id
    |> Frame.tunnel_id_from_string()
    |> Frame.fragment(7, payload, 512)
    |> Enum.each(&Engine.handle_inbound_frame(Frame.encode(&1)))

    _ = :sys.get_state(Engine)

    assert_receive {:tunnel_delivered,
                    %{payload_network: "meshcore", result: result, tunnel_id: tunnel_id}},
                   1_000

    assert tunnel_id == peer.tunnel_id

    # :bridge_disabled can only come from BridgeLink, so the engine preferred
    # inject_raw/2 over the companion's send_raw/2.
    assert result == {:error, :bridge_disabled}
  end

  test "MeshCore advert via tunnel is recorded with tunnel via" do
    alias Isthmus.Announce.Sightings
    alias Isthmus.Networks.MeshCore.{Advert, Crypto}

    {:ok, peer} =
      Tunnel.create_peer(%{
        name: "Local Test",
        peer_ref: "aa" <> String.duplicate("bb", 31),
        payload_network: "meshcore",
        carrier_network: "meshtastic"
      })

    {pub, seed} = Crypto.generate_keypair()
    hex = Base.encode16(pub, case: :lower)
    packet = Advert.build_flood(seed, pub, "Remote Phone")

    peer.tunnel_id
    |> Frame.tunnel_id_from_string()
    |> Frame.fragment(9, packet, 512)
    |> Enum.each(&Engine.handle_inbound_frame(Frame.encode(&1)))

    _ = :sys.get_state(Engine)

    assert_receive {:tunnel_delivered, %{payload_network: "meshcore"}}, 1_000

    sighting = Sightings.best_for("meshcore", hex)
    assert sighting
    assert sighting.meta["source"] == "tunnel_advert"
    assert sighting.meta["peer"] == "Local Test"
    assert sighting.meta["name"] == "Remote Phone"
    assert sighting.tunnel_id == peer.tunnel_id
  end

  test "outbox uses msg.payload (not the struct) when draining", %{peer: peer} do
    assert {:ok, msg} = Tunnel.send_payload(peer, "payload-bytes")
    assert is_binary(msg.payload)

    send(Engine, :tick)
    _ = :sys.get_state(Engine)

    refreshed = Outbox.get!(msg.id)
    assert refreshed.status in ["inflight", "acked", "pending"]
  end

  test "soft-heal runs for reticulum peers that lack a path after ping" do
    prev_ping = Application.get_env(:isthmus, :tunnel_ping_enabled, true)
    prev_heal = Application.get_env(:isthmus, :tunnel_heal_ms)
    Application.put_env(:isthmus, :tunnel_ping_enabled, true)
    Application.put_env(:isthmus, :tunnel_heal_ms, 60_000)

    on_exit(fn ->
      Application.put_env(:isthmus, :tunnel_ping_enabled, prev_ping)

      if prev_heal,
        do: Application.put_env(:isthmus, :tunnel_heal_ms, prev_heal),
        else: Application.delete_env(:isthmus, :tunnel_heal_ms)
    end)

    {:ok, peer} =
      Tunnel.create_peer(%{
        name: "RNS heal peer",
        peer_ref: String.duplicate("ab", 16),
        payload_network: "reticulum",
        carrier_network: "reticulum"
      })

    send(Engine, :ping)
    state = :sys.get_state(Engine)
    entry = Map.fetch!(state.liveness, peer.tunnel_id)

    assert is_integer(entry.last_heal_at)
    assert is_integer(state.last_announce_at)

    healed_at = entry.last_heal_at
    send(Engine, :ping)
    state2 = :sys.get_state(Engine)
    entry2 = Map.fetch!(state2.liveness, peer.tunnel_id)

    # Within heal interval — do not re-heal.
    assert entry2.last_heal_at == healed_at
  end

  test "soft-heal skips meshtastic peers", %{peer: peer} do
    prev = Application.get_env(:isthmus, :tunnel_ping_enabled, true)
    Application.put_env(:isthmus, :tunnel_ping_enabled, true)
    on_exit(fn -> Application.put_env(:isthmus, :tunnel_ping_enabled, prev) end)

    send(Engine, :ping)
    state = :sys.get_state(Engine)
    entry = Map.get(state.liveness, peer.tunnel_id, %{})

    refute Map.get(entry, :last_heal_at)
  end

  defp find_frame(outbound, pred) do
    Enum.find_value(outbound, fn %{payload: raw} ->
      case Frame.decode(raw) do
        {:ok, %Frame{} = frame, <<>>} -> if pred.(frame), do: raw
        _ -> nil
      end
    end)
  end

  defp control_op(%Frame{payload: payload}) do
    case Jason.decode(payload) do
      {:ok, %{"op" => op}} -> op
      _ -> nil
    end
  end
end
