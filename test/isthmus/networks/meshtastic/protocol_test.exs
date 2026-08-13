defmodule Isthmus.Networks.Meshtastic.ProtocolTest do
  use ExUnit.Case, async: true

  alias Isthmus.Networks.Meshtastic.Protocol
  alias Isthmus.Networks.Meshtastic.Protobuf

  test "frames want_config with big-endian length" do
    frame = Protocol.want_config_frame(123)
    assert <<0x94, 0xC3, 0x00, 0x02, 0x18, 0x7B>> = frame
  end

  test "decode_stream splits complete frames and keeps a partial" do
    first = Protocol.want_config_frame(1)
    {frames, rest} = Protocol.decode_stream(first <> <<0x94, 0xC3, 0x00>>)
    assert length(frames) == 1
    assert rest == <<0x94, 0xC3, 0x00>>
  end

  test "disabled channel encodes as empty" do
    encoded =
      Protocol.encode_channel(%{
        index: 2,
        name: "",
        psk: <<>>,
        role: Protocol.role_disabled()
      })

    parsed = Protocol.parse_channel(encoded)
    assert parsed.index == 2
    assert parsed.role == Protocol.role_disabled()
    assert parsed.empty?
    assert parsed.name == ""
  end

  test "channel encode/decode roundtrip" do
    psk = :crypto.strong_rand_bytes(16)

    encoded =
      Protocol.encode_channel(%{
        index: 3,
        name: "Lobby",
        psk: psk,
        role: Protocol.role_secondary()
      })

    parsed = Protocol.parse_channel(encoded)
    assert parsed.index == 3
    assert parsed.name == "Lobby"
    assert parsed.psk == psk
    assert parsed.role == Protocol.role_secondary()
    refute parsed.empty?
  end

  test "parse_frame reads FromRadio.channel" do
    inner =
      Protocol.encode_channel(%{
        index: 1,
        name: "Camp",
        psk: <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16>>,
        role: 2
      })

    payload = Protobuf.encode_message_field(10, inner)
    assert {:channel, ch} = Protocol.parse_frame(payload)
    assert ch.index == 1
    assert ch.name == "Camp"
  end

  test "parse_frame reads my_info node number" do
    inner = Protobuf.encode_varint_field(1, 0xDEADBEEF)
    payload = Protobuf.encode_message_field(3, inner)
    assert {:my_info, info} = Protocol.parse_frame(payload)
    assert info.my_node_num == 0xDEADBEEF
    assert info.node_id == "deadbeef"
  end

  test "send_channel_text_frame is a ToRadio packet to broadcast" do
    frame = Protocol.send_channel_text_frame(2, "hello")
    assert <<0x94, 0xC3, len::big-16, payload::binary-size(len)>> = frame
    fields = Protobuf.decode(payload)
    packet = Protobuf.bytes(fields, 1)
    parsed = Protocol.parse_mesh_packet(packet)
    assert parsed.to == Protocol.broadcast()
    assert parsed.channel == 2
    assert parsed.portnum == Protocol.port_text()
    assert parsed.payload == "hello"
  end

  test "channel invite URI is a Meshtastic add-channel link" do
    uri =
      Protocol.channel_invite_uri(%{
        name: "Lobby",
        psk: :crypto.strong_rand_bytes(16)
      })

    assert String.starts_with?(uri, "https://meshtastic.org/e/#")
    assert String.contains?(uri, "?add=true")
  end

  test "LoRa config encode/decode roundtrip preserves region and preset" do
    lora = %{
      use_preset: true,
      modem_preset: 4,
      bandwidth: 0,
      spread_factor: 0,
      coding_rate: 0,
      frequency_offset: 0.0,
      region: 3,
      hop_limit: 3,
      tx_enabled: true,
      tx_power: 0,
      channel_num: 0,
      override_duty_cycle: false,
      sx126x_rx_boosted_gain: true,
      override_frequency: 0.0,
      pa_fan_disabled: false,
      ignore_mqtt: false,
      config_ok_to_mqtt: false
    }

    parsed = Protocol.parse_lora_config(Protocol.encode_lora_config(lora))
    assert parsed.use_preset
    assert parsed.modem_preset == 4
    assert parsed.region == 3
    assert parsed.hop_limit == 3
    assert parsed.tx_enabled
    assert parsed.sx126x_rx_boosted_gain
  end

  test "LoRa custom mode roundtrip keeps bandwidth and override frequency" do
    lora = %{
      use_preset: false,
      modem_preset: 0,
      bandwidth: 125,
      spread_factor: 11,
      coding_rate: 5,
      frequency_offset: 0.0,
      region: 1,
      hop_limit: 4,
      tx_enabled: true,
      tx_power: 22,
      channel_num: 20,
      override_duty_cycle: false,
      sx126x_rx_boosted_gain: false,
      override_frequency: 906.875,
      pa_fan_disabled: false,
      ignore_mqtt: false,
      config_ok_to_mqtt: false
    }

    parsed = Protocol.parse_lora_config(Protocol.encode_lora_config(lora))
    refute parsed.use_preset
    assert parsed.bandwidth == 125
    assert parsed.spread_factor == 11
    assert parsed.coding_rate == 5
    assert parsed.tx_power == 22
    assert parsed.channel_num == 20
    assert_in_delta parsed.override_frequency, 906.875, 0.001
  end

  test "parse_frame reads FromRadio.config LoRa payload" do
    inner =
      Protocol.encode_lora_config(%{use_preset: true, modem_preset: 0, region: 1, hop_limit: 3})

    config = Protobuf.encode_message_field(6, inner)
    payload = Protobuf.encode_message_field(5, config)
    assert {:config, {:lora, lora}} = Protocol.parse_frame(payload)
    assert lora.region == 1
    assert lora.use_preset
  end

  test "get_config_admin_frame requests LORA_CONFIG" do
    frame = Protocol.get_config_admin_frame(0xABCD, :lora)
    assert <<0x94, 0xC3, len::big-16, payload::binary-size(len)>> = frame
    fields = Protobuf.decode(payload)
    packet = Protocol.parse_mesh_packet(Protobuf.bytes(fields, 1))
    assert packet.portnum == Protocol.port_admin()
    admin = Protobuf.decode(packet.payload)
    # AdminMessage.get_config_request = 5, ConfigType.LORA_CONFIG = 5
    assert Protobuf.varint(admin, 5) == 5
  end

  test "get_config_admin_frame requests DEVICE_CONFIG" do
    frame = Protocol.get_config_admin_frame(0xABCD, :device)
    assert <<0x94, 0xC3, len::big-16, payload::binary-size(len)>> = frame
    fields = Protobuf.decode(payload)
    packet = Protocol.parse_mesh_packet(Protobuf.bytes(fields, 1))
    admin = Protobuf.decode(packet.payload)
    # AdminMessage.get_config_request = 5, ConfigType.DEVICE_CONFIG = 0
    assert Protobuf.varint(admin, 5) == 0
  end

  test "device config roundtrip preserves role and tzdef" do
    device = %{
      Protocol.empty_device_config()
      | role: 2,
        node_info_broadcast_secs: 900,
        tzdef: "EST5EDT,M3.2.0,M11.1.0"
    }

    parsed = Protocol.parse_device_config(Protocol.encode_device_config(device))
    assert parsed.role == 2
    assert parsed.node_info_broadcast_secs == 900
    assert parsed.tzdef == "EST5EDT,M3.2.0,M11.1.0"
  end

  test "device config roundtrip preserves buzzer_mode" do
    device = %{Protocol.empty_device_config() | buzzer_mode: 1}
    parsed = Protocol.parse_device_config(Protocol.encode_device_config(device))
    assert parsed.buzzer_mode == 1
  end

  test "set_config_device_admin_frame wraps DeviceConfig" do
    passkey = <<9, 8, 7>>
    device = %{Protocol.empty_device_config() | tzdef: "UTC0"}
    frame = Protocol.set_config_device_admin_frame(0x1234, device, passkey)
    assert <<0x94, 0xC3, len::big-16, payload::binary-size(len)>> = frame
    fields = Protobuf.decode(payload)
    packet = Protocol.parse_mesh_packet(Protobuf.bytes(fields, 1))
    admin = Protobuf.decode(packet.payload)
    assert Protobuf.bytes(admin, 101) == passkey
    config = Protobuf.decode(Protobuf.bytes(admin, 34))
    parsed = Protocol.parse_device_config(Protobuf.bytes(config, 1))
    assert parsed.tzdef == "UTC0"
  end

  test "get_config_admin_frame requests POSITION_CONFIG" do
    frame = Protocol.get_config_admin_frame(0xABCD, :position)
    assert <<0x94, 0xC3, len::big-16, payload::binary-size(len)>> = frame
    fields = Protobuf.decode(payload)
    packet = Protocol.parse_mesh_packet(Protobuf.bytes(fields, 1))
    admin = Protobuf.decode(packet.payload)
    # AdminMessage.get_config_request = 5, ConfigType.POSITION_CONFIG = 1
    assert Protobuf.varint(admin, 5) == 1
  end

  test "set_time_admin_frame encodes Unix seconds and session passkey" do
    passkey = <<1, 2, 3, 4>>
    unix = 1_700_000_000
    frame = Protocol.set_time_admin_frame(0x1234, unix, passkey)
    assert <<0x94, 0xC3, len::big-16, payload::binary-size(len)>> = frame
    fields = Protobuf.decode(payload)
    packet = Protocol.parse_mesh_packet(Protobuf.bytes(fields, 1))
    assert packet.portnum == Protocol.port_admin()
    admin = Protobuf.decode(packet.payload)
    # AdminMessage.set_time_only = 43 (fixed32)
    assert Protobuf.field(admin, 43) == unix
    assert Protobuf.bytes(admin, 101) == passkey
  end

  test "parse_position reads Position.time" do
    payload = Protobuf.encode_fixed32_field(4, 1_700_000_123)
    assert Protocol.parse_position(payload).time == 1_700_000_123
    assert Protocol.parse_position(<<>>).time == 0
  end

  test "parse_telemetry_time reads Telemetry.time" do
    payload = Protobuf.encode_fixed32_field(1, 1_700_000_456)
    assert Protocol.parse_telemetry_time(payload) == 1_700_000_456
    assert Protocol.parse_telemetry_time(<<>>) == 0
  end

  test "parse_node_id accepts bang-prefixed hex" do
    assert {:ok, 0xDEADBEEF} = Protocol.parse_node_id("!deadbeef")
    assert {:ok, 0xDEADBEEF} = Protocol.parse_node_id("DEADBEEF")
    assert :error = Protocol.parse_node_id("nope")
  end

  test "parse_frame reads FromRadio.node_info with nested User" do
    user =
      Protobuf.encode_bytes_field(1, "!aabbccdd") <>
        Protobuf.encode_bytes_field(2, "Trail Node") <>
        Protobuf.encode_bytes_field(3, "TN")

    inner =
      Protobuf.encode_varint_field(1, 0xAABBCCDD) <>
        Protobuf.encode_message_field(2, user) <>
        Protobuf.encode_float_field(4, 8.5) <>
        Protobuf.encode_fixed32_field(5, 1_700_000_001) <>
        Protobuf.encode_message_field(3, Protobuf.encode_fixed32_field(4, 1_700_000_002))

    payload = Protobuf.encode_message_field(4, inner)
    assert {:node_info, info} = Protocol.parse_frame(payload)
    assert info.num == 0xAABBCCDD
    assert info.node_id == "aabbccdd"
    assert info.name == "Trail Node"
    assert info.short_name == "TN"
    assert_in_delta info.snr, 8.5, 0.01
    assert info.last_heard == 1_700_000_001
    assert info.position_time == 1_700_000_002
    assert info.hops == 0
  end

  test "parse_frame reads FromRadio.node_info hops_away" do
    user = Protobuf.encode_bytes_field(2, "Trail Node")

    inner =
      Protobuf.encode_varint_field(1, 0xAABBCCDD) <>
        Protobuf.encode_message_field(2, user) <>
        Protobuf.encode_varint_field(9, 4)

    payload = Protobuf.encode_message_field(4, inner)
    assert {:node_info, info} = Protocol.parse_frame(payload)
    assert info.hops == 4
  end

  test "parse_user prefers long_name then short_name" do
    user = Protocol.parse_user(Protobuf.encode_bytes_field(3, "TN"))
    assert user.name == "TN"
    assert user.short_name == "TN"

    user =
      Protocol.parse_user(
        Protobuf.encode_bytes_field(2, "Trail Node") <> Protobuf.encode_bytes_field(3, "TN")
      )

    assert user.name == "Trail Node"
  end

  test "parse_mesh_packet computes hops from hop_start minus hop_limit" do
    decoded = Protobuf.encode_varint_field(1, Protocol.port_nodeinfo())

    packet =
      Protobuf.encode_varint_field(1, 0xAABBCCDD) <>
        Protobuf.encode_message_field(4, decoded) <>
        Protobuf.encode_varint_field(9, 2) <>
        Protobuf.encode_varint_field(14, 5)

    parsed = Protocol.parse_mesh_packet(packet)
    assert parsed.from == 0xAABBCCDD
    assert parsed.portnum == Protocol.port_nodeinfo()
    assert parsed.hops == 3
  end
end
