defmodule Isthmus.Networks.Meshtastic.CompanionTest do
  use Isthmus.DataCase, async: false

  alias Isthmus.Networks.Meshtastic.Companion
  alias Isthmus.Networks.Meshtastic.Companion.Admin

  test "stay_connected? is true only for an online UART on the same port" do
    online = %{status: :online, uart: self(), port: "/dev/ttyUSB0", fixed_port: true}
    assert Companion.stay_connected?(online)

    refute Companion.stay_connected?(%{online | status: :error})
    refute Companion.stay_connected?(%{online | uart: nil})
    refute Companion.stay_connected?(%{status: :disconnected, uart: nil, port: nil})
  end

  test "stay_connected? treats an online BLE transport as connected" do
    online = %{
      status: :online,
      transport_kind: :ble,
      transport: %{type: :ble},
      uart: nil,
      fixed_port: true
    }

    assert Companion.stay_connected?(online)
    refute Companion.stay_connected?(%{online | transport: nil})
  end

  test "ble_key prefixes bleak addresses" do
    assert Companion.ble_key("AA:BB") == "ble:AA:BB"
    assert Companion.ble_key("ble:AA:BB") == "ble:AA:BB"
    assert Companion.ble_key("aa:bb") == "ble:AA:BB"
    assert Companion.ble_address("ble:AA:BB") == "AA:BB"
    assert Companion.same_ble_address?("aa:bb:cc", "ble:AA:BB:CC")
    assert Companion.ble_link_lost?("not_connected")
    assert Companion.ble_link_lost?(:not_connected)
    refute Companion.ble_link_lost?(:timeout)
    assert Companion.ble_retryable_error?("not_found:F7:DE:1C:90:E1:EC")
  end

  test "disconnect_unidentified is a no-op when no radio is online" do
    assert :ok = Companion.disconnect_unidentified()
  end

  test "health is disabled when no Meshtastic radio is detected" do
    health = Companion.health()
    assert health.status == :disabled
    assert health.last_error =~ "no companion detected"
  end

  test "send_channel_text fails when disconnected" do
    assert {:error, :not_connected} = Companion.send_channel_text(1, "hi")
  end

  test "set_lora_config fails when disconnected" do
    assert {:error, :not_connected} =
             Companion.set_lora_config(%{
               "region" => "1",
               "mode" => "preset",
               "modem_preset" => "0"
             })
  end

  test "set_settings fails when disconnected" do
    assert {:error, :not_connected} =
             Companion.set_settings(%{"device" => %{"buzzer_mode" => "disabled"}})
  end

  test "set_time fails when disconnected" do
    assert {:error, :not_connected} = Companion.set_time()
  end

  test "clear_channel fails when disconnected" do
    assert {:error, :not_connected} = Companion.clear_channel(2)
  end

  test "admin handshake waits longer on BLE than USB" do
    assert Admin.timeout_ms() == 4_000
    assert Admin.timeout_ms(%{transport_kind: :usb}) == 4_000
    assert Admin.timeout_ms(%{}) == 4_000
    assert Admin.timeout_ms(%{transport_kind: :ble}) == 15_000
  end

  test "list_channels returns eight placeholder slots before a dump" do
    channels = Companion.list_channels()
    assert length(channels) == 8
    assert Enum.all?(channels, & &1.empty?)
  end

  test "list_health includes the primary companion" do
    health = Companion.health()
    listed = Companion.list_health()

    assert Enum.any?(listed, fn h -> h.status == health.status end)
  end

  test "inject_inbound publishes channel messages" do
    Phoenix.PubSub.subscribe(Isthmus.PubSub, "meshtastic:inbound")

    Companion.inject_inbound(:channel, %{
      channel_idx: 2,
      body: "from the trail",
      from_ref: "deadbeef"
    })

    assert_receive {:meshtastic_channel, attrs}, 1_000
    assert attrs.channel_idx == 2
    assert attrs.body == "from the trail"
    assert attrs.from_ref == "deadbeef"

    # PubSub handle_info casts ingest; two sync points drain both messages
    # before the sandbox owner exits.
    _ = :sys.get_state(Isthmus.Gateway.Translator)
    _ = :sys.get_state(Isthmus.Gateway.Translator)
  end

  test "inject_inbound records nodeinfo as a meshtastic sighting" do
    Phoenix.PubSub.subscribe(Isthmus.PubSub, "announce:sightings")

    Companion.inject_inbound(:nodeinfo, %{
      node_id: "!aabbccdd",
      name: "Trail Node",
      hops: 2,
      snr: 6.25
    })

    assert_receive {:sighting, _}, 1_000

    assert %{network: "meshtastic", hops: 2, meta: meta} =
             Isthmus.Announce.Sightings.best_for("meshtastic", "aabbccdd")

    assert meta["name"] == "Trail Node"
    assert meta["source"] == "nodeinfo"
  end

  test "inject_inbound records node_db hops_away as hops" do
    Phoenix.PubSub.subscribe(Isthmus.PubSub, "announce:sightings")

    Companion.inject_inbound(:nodeinfo, %{
      node_id: "!ccddeeff",
      name: "Ridge",
      hops_away: 3
    })

    assert_receive {:sighting, _}, 1_000
    assert %{hops: 3} = Isthmus.Announce.Sightings.best_for("meshtastic", "ccddeeff")
  end

  test "queued Primary TEXT_MESSAGE is stored with packet id" do
    alias Isthmus.Networks.Meshtastic.Companion.Inbound
    alias Isthmus.Networks.Meshtastic.Protocol

    state = %{
      my_info: %{my_node_num: 1, node_id: "00000001"},
      port: "/dev/ttyTEST",
      received: 0
    }

    pkt = %{
      portnum: Protocol.port_text(),
      from: 0xAABBCCDD,
      to: Protocol.broadcast(),
      channel: 0,
      id: 7_701,
      rx_time: 1_700_000_300,
      payload: "held on radio"
    }

    _ = Inbound.handle_packet(state, pkt)
    _ = :sys.get_state(Isthmus.Gateway.Translator)
    _ = :sys.get_state(Isthmus.Gateway.Translator)

    assert Enum.any?(Isthmus.Messages.list_recent(20), fn row ->
             row.network == "meshtastic" and row.body == "held on radio" and
               row.external_id == "mt-7701"
           end)
  end

  test "Store and Forward broadcast history is stored as Primary text" do
    alias Isthmus.Networks.Meshtastic.Companion.Inbound
    alias Isthmus.Networks.Meshtastic.Protocol
    alias Isthmus.Networks.Meshtastic.Protobuf

    state = %{
      my_info: %{my_node_num: 1, node_id: "00000001"},
      port: "/dev/ttyTEST",
      received: 0
    }

    payload =
      Protobuf.encode_varint_field(1, Protocol.sf_router_text_broadcast()) <>
        Protobuf.encode_bytes_field(5, "sf replay")

    pkt = %{
      portnum: Protocol.port_store_forward(),
      from: 0x11223344,
      to: 1,
      channel: 0,
      id: 8_802,
      rx_time: 1_700_000_400,
      payload: payload
    }

    _ = Inbound.handle_packet(state, pkt)
    _ = :sys.get_state(Isthmus.Gateway.Translator)
    _ = :sys.get_state(Isthmus.Gateway.Translator)

    assert Enum.any?(Isthmus.Messages.list_recent(20), fn row ->
             row.network == "meshtastic" and row.body == "sf replay" and
               row.external_id == "mt-8802"
           end)
  end

  test "ble_frame notify is applied like a USB FromRadio payload" do
    alias Isthmus.Networks.Meshtastic.Companion.Inbound
    alias Isthmus.Networks.Meshtastic.Companion.Status
    alias Isthmus.Networks.Meshtastic.Protobuf

    inner = Protobuf.encode_varint_field(1, 0xAABBCCDD)
    payload = Protobuf.encode_message_field(3, inner)

    state =
      Inbound.handle_payload(
        %{
          my_info: nil,
          last_error: "x",
          received: 0,
          sent: 0,
          port: "/dev/ttyBLETEST",
          status: :online,
          lora: %{},
          device: %{},
          channels: %{},
          fixed_port: true
        },
        payload
      )

    assert get_in(state, [:my_info, :node_id]) == "aabbccdd"
    Status.drop_ets(state)
  end

  test "FromRadio LoRa config is stored so the settings dialog can show region" do
    alias Isthmus.Networks.Meshtastic.Companion.Inbound
    alias Isthmus.Networks.Meshtastic.Companion.Status
    alias Isthmus.Networks.Meshtastic.Protobuf
    alias Isthmus.Networks.Meshtastic.Protocol

    inner =
      Protocol.encode_lora_config(%{use_preset: true, modem_preset: 0, region: 1, hop_limit: 3})

    payload =
      Protobuf.encode_varint_field(1, 7) <>
        Protobuf.encode_message_field(5, Protobuf.encode_message_field(6, inner))

    state =
      Inbound.handle_payload(
        %{
          my_info: %{my_node_num: 1, node_id: "aabbccdd"},
          last_error: nil,
          received: 0,
          sent: 0,
          port: "/dev/ttyLORATEST",
          status: :online,
          lora: %{},
          device: %{},
          channels: %{},
          fixed_port: true,
          transport_kind: :usb,
          uart: nil
        },
        payload
      )

    assert state.lora.region == 1
    assert Companion.lora_config("/dev/ttyLORATEST").region == 1
    assert Companion.health("/dev/ttyLORATEST").region == 1
    Status.drop_ets(state)
  end

  test "FromRadio channel is published immediately so Sync can show names before dump complete" do
    alias Isthmus.Networks.Meshtastic.Companion.Inbound
    alias Isthmus.Networks.Meshtastic.Companion.Status
    alias Isthmus.Networks.Meshtastic.Protobuf
    alias Isthmus.Networks.Meshtastic.Protocol

    inner =
      Protocol.encode_channel(%{
        index: 4,
        name: "Lobby",
        psk: :crypto.strong_rand_bytes(16),
        role: Protocol.role_secondary()
      })

    payload = Protobuf.encode_message_field(10, inner)
    port = "/dev/ttyCHANTTEST"

    state =
      Inbound.handle_payload(
        %{
          my_info: %{my_node_num: 1, node_id: "aabbccdd"},
          last_error: nil,
          received: 0,
          sent: 0,
          port: port,
          status: :online,
          lora: %{},
          device: %{},
          channels: %{},
          fixed_port: true,
          transport_kind: :usb,
          uart: nil
        },
        payload
      )

    slots = Companion.list_channels(port)
    assert Enum.at(slots, 4).name == "Lobby"
    refute Enum.at(slots, 4).empty?
    Status.drop_ets(state)
  end
end
