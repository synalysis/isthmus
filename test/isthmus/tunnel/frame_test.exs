defmodule Isthmus.Tunnel.FrameTest do
  use ExUnit.Case, async: true

  alias Isthmus.Tunnel.Frame

  test "encode/decode round-trip" do
    payload = :crypto.strong_rand_bytes(40)

    frame = %Frame{
      tunnel_id: :crypto.strong_rand_bytes(16),
      flags: Frame.flag_data(),
      frag_idx: 0,
      frag_cnt: 1,
      seq: 7,
      payload_hash16: Frame.hash16(payload),
      payload: payload
    }

    encoded = Frame.encode(frame)
    assert {:ok, decoded, <<>>} = Frame.decode(encoded)
    assert decoded.seq == 7
    assert decoded.payload == payload
  end

  test "fragment respects mtu" do
    payload = :crypto.strong_rand_bytes(500)
    frames = Frame.fragment(<<1::128>>, 1, payload, 200)
    assert length(frames) > 1
    assert Enum.all?(frames, fn f -> byte_size(Frame.encode(f)) <= 200 end)
  end

  test "control_frame round-trip" do
    payload = ~s({"op":"announce","ref":"abc"})
    frame = Frame.control_frame(<<9::128>>, 3, payload)
    assert Bitwise.band(frame.flags, Frame.flag_control()) != 0

    encoded = Frame.encode(frame)
    assert {:ok, decoded, <<>>} = Frame.decode(encoded)
    assert decoded.payload == payload
    assert decoded.seq == 3
  end
end
