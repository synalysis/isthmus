defmodule Isthmus.Networks.MeshCore.ProtocolTest do
  use ExUnit.Case, async: true

  alias Isthmus.Networks.MeshCore.Protocol

  test "encode_outbound wraps USB and leaves BLE raw" do
    frame = Protocol.device_query_frame()
    assert Protocol.encode_outbound(:usb, frame) == Protocol.encode_usb_frame(frame)
    assert Protocol.encode_outbound(:ble, frame) == frame
  end

  test "parse_device_info reads version and model" do
    build = String.pad_trailing("d929643", 12, <<0>>)
    model = String.pad_trailing("Wio Tracker L1", 40, <<0>>)
    ver = String.pad_trailing("1.17.1", 20, <<0>>)

    info =
      Protocol.parse_device_info(
        <<3, 8, 8, 0::little-32, build::binary, model::binary, ver::binary>>
      )

    assert info.version == "1.17.1"
    assert info.model == "Wio Tracker L1"
    assert info.max_channels == 8
  end

  test "device_query_frame includes app protocol version" do
    assert Protocol.device_query_frame() == <<0x16, 3>>
    assert Protocol.device_query_frame(10) == <<0x16, 10>>
  end

  test "app_start_frame reserves bytes 1..7 before app name" do
    assert Protocol.app_start_frame("Isthmus") ==
             <<0x01, 0, 0, 0, 0, 0, 0, 0, "Isthmus", 0>>
  end

  test "get_channel_frame encodes index" do
    assert Protocol.get_channel_frame(3) == <<0x1F, 3>>
  end

  test "set_channel_frame pads name and secret to 50 bytes" do
    frame = Protocol.set_channel_frame(1, "Trail", :binary.copy(<<0xAB>>, 16))
    assert byte_size(frame) == 50
    assert <<0x20, 1, _name::binary-32, _secret::binary-16>> = frame
  end

  test "send_channel_txt_frame includes channel index and text" do
    frame = Protocol.send_channel_txt_frame(2, "hello")
    assert <<0x03, 0, 2, _ts::little-32, "hello">> = frame
  end

  test "parse_frame channel_info" do
    name = String.pad_trailing("Camp", 32, <<0>>)
    secret = :binary.copy(<<0xCD>>, 16)
    frame = <<0x12, 1, name::binary, secret::binary>>

    assert {:channel_info, ch} = Protocol.parse_frame(frame)
    assert ch.index == 1
    assert ch.name == "Camp"
    assert ch.secret_hex == String.duplicate("cd", 16)
    refute ch.empty?
  end

  test "parse_frame empty channel_info" do
    frame = <<0x12, 4, :binary.copy(<<0>>, 32)::binary, :binary.copy(<<0>>, 16)::binary>>
    assert {:channel_info, ch} = Protocol.parse_frame(frame)
    assert ch.empty?
  end

  test "parse_frame channel_msg standard" do
    frame = <<0x08, 3, 0, 0, 1_234::little-32, "hi there">>
    assert {:channel_msg, msg} = Protocol.parse_frame(frame)
    assert msg.channel_idx == 3
    assert msg.body == "hi there"
    assert msg.timestamp == 1_234
  end

  test "sync_next_message_frame is CMD_SYNC_NEXT_MESSAGE" do
    assert Protocol.sync_next_message_frame() == <<10>>
  end

  test "parse_frame no_more_messages" do
    assert Protocol.parse_frame(<<10>>) == {:no_more_messages, true}
  end

  test "parse_frame channel_msg v3" do
    frame = <<0x11, 10, 0, 0, 2, 0, 0, 99::little-32, "v3 msg">>
    assert {:channel_msg, msg} = Protocol.parse_frame(frame)
    assert msg.channel_idx == 2
    assert msg.body == "v3 msg"
    assert msg.snr == 10
  end

  test "parse_frame self_info extracts our own public key, name and radio" do
    pubkey = :binary.copy(<<0xA7>>, 32)

    # [code][adv_type][tx_power][max_tx_power][pub_key x32][lat][lon]
    # [multi_acks][adv_loc_policy][telemetry][manual_add][freq][bw][sf][cr][name]
    frame =
      <<0x05, 1, 20, 30, pubkey::binary, 1_000_000::little-signed-32,
        -2_000_000::little-signed-32, 0, 1, 0, 0, 867_500::little-32, 250_000::little-32, 11, 5,
        "Isthmus Node", 0>>

    assert {:self_info, info} = Protocol.parse_frame(frame)
    assert info.public_key == String.duplicate("a7", 32)
    assert info.adv_type == 1
    assert info.tx_power == 20
    assert info.max_tx_power == 30
    assert info.name == "Isthmus Node"
    assert_in_delta info.freq_mhz, 867.5, 0.001
    assert_in_delta info.bw_khz, 250.0, 0.001
    assert info.sf == 11
    assert info.cr == 5
  end

  test "set_radio_params_frame and set_tx_power_frame encode protocol cmds" do
    frame = Protocol.set_radio_params_frame(910.525, 62.5, 7, 5)
    assert <<0x0B, freq::little-32, bw::little-32, 7, 5>> = frame
    assert freq == 910_525
    assert bw == 62_500

    assert Protocol.set_tx_power_frame(10) == <<0x0C, 10>>
  end

  test "parse_frame self_info without the trailing name still yields the key" do
    pubkey = :binary.copy(<<0x5B>>, 32)
    frame = <<0x05, 1, 20, 30, pubkey::binary>>

    assert {:self_info, info} = Protocol.parse_frame(frame)
    assert info.public_key == String.duplicate("5b", 32)
    assert is_nil(info.name)
  end

  test "parse_frame self_info too short to hold a key falls back to raw" do
    assert {:self_info, %{raw: <<1, 2>>}} = Protocol.parse_frame(<<0x05, 1, 2>>)
  end

  test "companion_probe_reply? requires a plausible DEVICE_INFO payload" do
    rest = <<3, 100, 8>> <> :binary.copy(<<0>>, 77)
    assert Protocol.companion_probe_reply?(<<13, rest::binary>>)

    # CR (0x0D) with no payload — typical ESP32 boot-log false positive
    refute Protocol.companion_probe_reply?(<<13>>)
    refute Protocol.companion_probe_reply?(<<13, 3, 0, 8>>)

    # SELF_INFO is the APP_START reply, not DEVICE_QUERY
    refute Protocol.companion_probe_reply?(<<5, 1, 2>>)
  end

  test "parse_frame contact exposes hops from out_path_len" do
    pubkey = :binary.copy(<<0x11>>, 32)
    path = <<0xAA, 0xBB, 0xCC>> <> :binary.copy(<<0>>, 61)
    name = String.pad_trailing("Camp", 32, <<0>>)

    frame =
      <<0x03, pubkey::binary, 1, 0, 3::signed-8, path::binary, name::binary, 0::little-32,
        0::signed-little-32, 0::signed-little-32, 0::little-32>>

    assert {:contact, c} = Protocol.parse_frame(frame)
    assert c.hops == 3
    assert c.out_path_len == 3
    assert c.out_path == <<0xAA, 0xBB, 0xCC>>
    assert c.name == "Camp"
  end

  test "parse_frame contact with unknown path has nil hops" do
    pubkey = :binary.copy(<<0x22>>, 32)
    path = :binary.copy(<<0>>, 64)
    name = String.pad_trailing("Lost", 32, <<0>>)

    frame =
      <<0x03, pubkey::binary, 1, 0, -1::signed-8, path::binary, name::binary, 0::little-32,
        0::signed-little-32, 0::signed-little-32, 0::little-32>>

    assert {:contact, c} = Protocol.parse_frame(frame)
    assert is_nil(c.hops)
    assert c.out_path_len == 0
  end
end
