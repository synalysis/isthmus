defmodule Isthmus.Networks.MeshCore.BridgeFrameTest do
  use ExUnit.Case, async: true

  alias Isthmus.Networks.MeshCore.BridgeFrame

  defp frame(packet), do: BridgeFrame.encode!(packet)

  # Captured from the firmware's own BridgeSerialFramer::encode by compiling
  # src/helpers/bridges/{BridgeSerialFramer,BridgeCodec}.cpp natively. If these
  # drift, the two implementations no longer agree on the wire.
  @golden [
    {"112233", "C03E0003112233AA66"},
    {"0400ABCDEF010203", "C03E00080400ABCDEF010203F473"},
    {"5A", "C03E00015A5A5A"},
    {"6162636465", "C03E00056162636465C8F0"}
  ]

  describe "golden vectors from the firmware framer" do
    test "encode matches the C++ implementation byte for byte" do
      for {payload_hex, frame_hex} <- @golden do
        payload = Base.decode16!(payload_hex)
        assert {:ok, frame} = BridgeFrame.encode(payload)

        assert Base.encode16(frame) == frame_hex,
               "payload #{payload_hex} encoded to #{Base.encode16(frame)}, firmware says #{frame_hex}"
      end
    end

    test "decode accepts frames produced by the C++ implementation" do
      for {payload_hex, frame_hex} <- @golden do
        payload = Base.decode16!(payload_hex)
        assert {[^payload], <<>>, _} = BridgeFrame.decode(Base.decode16!(frame_hex))
      end
    end

    test "a 256-byte packet frames to the firmware's length encoding" do
      payload = :binary.copy(<<0x5A>>, 256)
      assert {:ok, <<0xC0, 0x3E, 0x01, 0x00, rest::binary>>} = BridgeFrame.encode(payload)
      assert <<^payload::binary-256, 0x5A, 0x5A>> = rest
    end
  end

  describe "fletcher16/1" do
    test "matches the canonical test vector" do
      assert BridgeFrame.fletcher16("abcde") == 0xC8F0
    end

    test "empty input checksums to zero" do
      assert BridgeFrame.fletcher16("") == 0
    end
  end

  describe "encode/1" do
    test "builds magic, big-endian length, payload and checksum" do
      packet = <<0x11, 0x22, 0x33>>
      assert {:ok, encoded} = BridgeFrame.encode(packet)

      assert <<0xC0, 0x3E, len::big-16, ^packet::binary-3, checksum::big-16>> = encoded
      assert len == 3
      assert checksum == BridgeFrame.fletcher16(packet)
      assert byte_size(encoded) == byte_size(packet) + BridgeFrame.overhead()
    end

    test "rejects empty packets and anything over the firmware limit" do
      assert {:error, :invalid_length} = BridgeFrame.encode(<<>>)
      assert {:error, :invalid_length} = BridgeFrame.encode(:binary.copy(<<0>>, 257))
      assert {:ok, _} = BridgeFrame.encode(:binary.copy(<<0>>, 256))
    end

    test "encode!/1 raises rather than returning a tuple" do
      assert_raise ArgumentError, fn -> BridgeFrame.encode!(<<>>) end
    end
  end

  describe "decode/1" do
    test "round-trips a single packet" do
      packet = <<0x04, 0x00, 0xAB, 0xCD>>
      assert {[^packet], <<>>, stats} = BridgeFrame.decode(frame(packet))
      assert stats.checksum_errors == 0
      assert stats.dropped_bytes == 0
    end

    test "decodes several frames from one read" do
      a = <<1, 2, 3>>
      b = <<4, 5>>
      c = <<6>>

      assert {[^a, ^b, ^c], <<>>, _} = BridgeFrame.decode(frame(a) <> frame(b) <> frame(c))
    end

    test "holds an incomplete frame as the remainder" do
      packet = <<9, 9, 9, 9>>
      encoded = frame(packet)
      {head, _tail} = :erlang.split_binary(encoded, byte_size(encoded) - 3)

      assert {[], ^head, _} = BridgeFrame.decode(head)

      # feeding the rest completes it
      assert {[^packet], <<>>, _} = BridgeFrame.decode(encoded)
    end

    test "skips leading garbage and counts the dropped bytes" do
      packet = <<7, 7>>
      assert {[^packet], <<>>, stats} = BridgeFrame.decode(<<0xFF, 0x00, 0xC0>> <> frame(packet))
      assert stats.dropped_bytes == 3
    end

    test "keeps a trailing partial magic byte across reads" do
      packet = <<3, 1, 4>>
      encoded = frame(packet)

      assert {[], <<0xC0>>, _} = BridgeFrame.decode(<<0xAA, 0xC0>>)

      <<0xC0, rest::binary>> = encoded
      assert {[^packet], <<>>, _} = BridgeFrame.decode(<<0xC0>> <> rest)
    end

    test "drops nothing but the noise when no magic is present" do
      assert {[], <<>>, stats} = BridgeFrame.decode(<<1, 2, 3, 4>>)
      assert stats.dropped_bytes == 4
    end

    test "rejects a corrupt checksum and resyncs onto the next frame" do
      good = <<5, 5, 5>>
      encoded = frame(good)

      # flip the final checksum byte
      head_len = byte_size(encoded) - 1
      <<head::binary-size(^head_len), last>> = encoded
      corrupt = head <> <<Bitwise.bxor(last, 0xFF)>>

      assert {[^good], <<>>, stats} = BridgeFrame.decode(corrupt <> encoded)
      assert stats.checksum_errors == 1
    end

    test "treats an oversized length field as garbage" do
      packet = <<8, 8>>
      bogus = <<0xC0, 0x3E, 0xFF, 0xFF, 0x00, 0x00>>

      assert {[^packet], <<>>, stats} = BridgeFrame.decode(bogus <> frame(packet))
      assert stats.dropped_bytes > 0
    end

    test "treats a zero length field as garbage" do
      packet = <<2>>
      bogus = <<0xC0, 0x3E, 0x00, 0x00>>

      assert {[^packet], <<>>, _} = BridgeFrame.decode(bogus <> frame(packet))
    end

    test "a plausible but corrupt length stalls until the bytes arrive" do
      # The decoder cannot tell this is garbage yet, so it waits rather than
      # discarding what might be a legitimate frame in flight.
      partial = <<0xC0, 0x3E, 0x00, 0x40, 0x01, 0x02>>
      assert {[], ^partial, _} = BridgeFrame.decode(partial)
    end

    test "resyncs onto a real frame once a corrupt one fails its checksum" do
      inner = <<0xAB, 0xCD>>
      bogus = <<0xC0, 0x3E, 0x00, 0x08>> <> :binary.copy(<<0x01>>, 10)

      assert {[^inner], <<>>, stats} = BridgeFrame.decode(bogus <> frame(inner))
      assert stats.checksum_errors == 1
      assert stats.dropped_bytes > 0
    end

    test "handles a maximum-size packet" do
      packet = :binary.copy(<<0x5A>>, 256)
      assert {[^packet], <<>>, _} = BridgeFrame.decode(frame(packet))
    end

    test "byte-at-a-time feeding reassembles correctly" do
      packet = <<1, 2, 3, 4, 5>>
      encoded = frame(packet)

      {decoded, leftover} =
        encoded
        |> :binary.bin_to_list()
        |> Enum.reduce({[], <<>>}, fn byte, {acc, buffer} ->
          {packets, rest, _stats} = BridgeFrame.decode(buffer <> <<byte>>)
          {acc ++ packets, rest}
        end)

      assert decoded == [packet]
      assert leftover == <<>>
    end
  end
end
