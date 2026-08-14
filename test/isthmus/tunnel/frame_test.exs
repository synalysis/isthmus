defmodule Isthmus.Tunnel.FrameTest do
  use ExUnit.Case, async: true

  alias Isthmus.Tunnel.Frame

  @mac_key :crypto.hash(:sha256, "test-tunnel-mac")

  test "encode/decode round-trip with HMAC" do
    payload = :crypto.strong_rand_bytes(40)

    frame = %Frame{
      tunnel_id: :crypto.strong_rand_bytes(16),
      flags: Frame.flag_data(),
      frag_idx: 0,
      frag_cnt: 1,
      seq: 7,
      payload: payload
    }

    encoded = Frame.encode(frame, @mac_key)
    assert {:ok, decoded, <<>>} = Frame.decode(encoded)
    assert decoded.seq == 7
    assert decoded.payload == payload
    assert Frame.valid_mac?(decoded, @mac_key)
    refute Frame.valid_mac?(decoded, :crypto.hash(:sha256, "other"))
  end

  test "fragment respects mtu" do
    payload = :crypto.strong_rand_bytes(500)
    frames = Frame.fragment(<<1::128>>, 1, payload, 200)
    assert length(frames) > 1
    assert Enum.all?(frames, fn f -> byte_size(Frame.encode(f, @mac_key)) <= 200 end)
  end

  test "control_frame round-trip" do
    payload = ~s({"op":"announce","ref":"abc"})
    frame = Frame.control_frame(<<9::128>>, 3, payload)
    assert Bitwise.band(frame.flags, Frame.flag_control()) != 0

    encoded = Frame.encode(frame, @mac_key)
    assert {:ok, decoded, <<>>} = Frame.decode(encoded)
    assert decoded.payload == payload
    assert decoded.seq == 3
    assert Frame.valid_mac?(decoded, @mac_key)
  end

  test "decode rejects oversized fragment counts" do
    frame = %Frame{
      tunnel_id: <<1::128>>,
      flags: Frame.flag_data(),
      frag_idx: 0,
      frag_cnt: Frame.max_frag_cnt() + 1,
      seq: 1,
      payload: <<"x">>
    }

    encoded = Frame.encode(%{frame | frag_cnt: 1}, @mac_key)
    # Tamper frag_cnt in the binary after magic+version+tunnel_id+flags
    assert {:error, :invalid_frame} =
             encoded
             |> put_frag_cnt(33)
             |> Frame.decode()
  end

  defp put_frag_cnt(
         <<magic::binary-4, ver, tid::binary-16, flags, _idx::16, _cnt::16, rest::binary>>,
         cnt
       ) do
    <<magic::binary, ver, tid::binary, flags, 0::16, cnt::16, rest::binary>>
  end
end
