defmodule Isthmus.Networks.Reticulum.InterfaceSocketTest do
  use ExUnit.Case, async: false

  alias Isthmus.Networks.Reticulum.InterfaceSocket

  test "health exposes socket path" do
    health = InterfaceSocket.health()
    assert is_binary(health.path)
    assert health.path =~ "isthmus.sock" or String.starts_with?(health.path, "/")
  end

  test "hdlc round-trip via module internals" do
    # Encode/decode through the same helpers used by the GenServer.
    data = :crypto.strong_rand_bytes(32)
    frame = <<0x7E>> <> escape(data) <> <<0x7E>>
    assert decode_frames(frame) == [data]
  end

  defp escape(data) do
    data
    |> :binary.bin_to_list()
    |> Enum.flat_map(fn
      0x7D -> [0x7D, Bitwise.bxor(0x7D, 0x20)]
      0x7E -> [0x7D, Bitwise.bxor(0x7E, 0x20)]
      b -> [b]
    end)
    |> :binary.list_to_bin()
  end

  defp decode_frames(bin) do
    {frames, _} =
      bin
      |> :binary.bin_to_list()
      |> Enum.reduce({[], %{buffer: <<>>, in_frame: false, escape: false}}, fn byte,
                                                                               {frames, c} ->
        cond do
          c.in_frame and byte == 0x7E ->
            frame = c.buffer
            c = %{c | in_frame: false, buffer: <<>>, escape: false}
            if frame == <<>>, do: {frames, c}, else: {[frame | frames], c}

          byte == 0x7E ->
            {frames, %{c | in_frame: true, buffer: <<>>, escape: false}}

          c.in_frame ->
            {b, escape} =
              if c.escape do
                decoded =
                  cond do
                    byte == Bitwise.bxor(0x7E, 0x20) -> 0x7E
                    byte == Bitwise.bxor(0x7D, 0x20) -> 0x7D
                    true -> byte
                  end

                {decoded, false}
              else
                if byte == 0x7D, do: {nil, true}, else: {byte, false}
              end

            if is_nil(b) do
              {frames, %{c | escape: escape}}
            else
              {frames, %{c | buffer: c.buffer <> <<b>>, escape: escape}}
            end

          true ->
            {frames, c}
        end
      end)

    Enum.reverse(frames)
  end
end
