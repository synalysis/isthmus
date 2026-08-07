defmodule Isthmus.Networks.MeshCore.ProtocolTest do
  use ExUnit.Case, async: true

  alias Isthmus.Networks.MeshCore.Protocol

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

  test "parse_frame channel_msg v3" do
    frame = <<0x11, 10, 0, 0, 2, 0, 0, 99::little-32, "v3 msg">>
    assert {:channel_msg, msg} = Protocol.parse_frame(frame)
    assert msg.channel_idx == 2
    assert msg.body == "v3 msg"
    assert msg.snr == 10
  end
end
