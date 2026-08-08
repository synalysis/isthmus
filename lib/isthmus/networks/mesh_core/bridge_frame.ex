defmodule Isthmus.Networks.MeshCore.BridgeFrame do
  @moduledoc """
  Framing for MeshCore's `RS232Bridge` packet stream.

  A bridge-enabled repeater forwards raw `mesh::Packet` bytes over a serial
  link, which is how MeshCore islands are joined. Unlike the companion
  protocol, this carries every packet the repeater relays — adverts, DMs, ACKs
  and path discovery alike.

  Wire format (all fields big-endian, 6 bytes of overhead):

      [0]        0xC0
      [1]        0x3E
      [2..3]     payload length
      [4..4+n-1] raw mesh packet
      [4+n..]    Fletcher-16 over the payload only

  Mirrors `RS232Bridge::loop/sendPacket` and `BridgeBase::fletcher16`.
  """

  import Bitwise

  @magic_hi 0xC0
  @magic_lo 0x3E
  @magic <<@magic_hi, @magic_lo>>

  # MAX_TRANS_UNIT (255) + 1, matching the firmware's own length guard.
  @max_packet 256
  @overhead 6

  @type stats :: %{checksum_errors: non_neg_integer(), dropped_bytes: non_neg_integer()}

  def magic, do: @magic
  def max_packet_size, do: @max_packet
  def overhead, do: @overhead

  @doc """
  Wrap a raw mesh packet in a bridge frame.

  Returns `{:error, :invalid_length}` for empty packets or anything the
  firmware would reject on receipt.
  """
  @spec encode(binary()) :: {:ok, binary()} | {:error, :invalid_length}
  def encode(packet)
      when is_binary(packet) and byte_size(packet) > 0 and byte_size(packet) <= @max_packet do
    {:ok,
     <<@magic_hi, @magic_lo, byte_size(packet)::big-16, packet::binary,
       fletcher16(packet)::big-16>>}
  end

  def encode(packet) when is_binary(packet), do: {:error, :invalid_length}

  @spec encode!(binary()) :: binary()
  def encode!(packet) do
    case encode(packet) do
      {:ok, frame} ->
        frame

      {:error, :invalid_length} ->
        raise ArgumentError,
              "mesh packet must be 1..#{@max_packet} bytes, got #{byte_size(packet)}"
    end
  end

  @doc """
  Pull every complete frame out of `buffer`.

  Returns the decoded packets, the unconsumed remainder to carry into the next
  read, and counters for bytes discarded during resync and frames that failed
  their checksum.

  The remainder is bounded: without a magic word at most one trailing byte is
  kept (in case the magic straddles two reads), and with one at most a single
  maximum-size frame.
  """
  @spec decode(binary()) :: {[binary()], binary(), stats()}
  def decode(buffer) when is_binary(buffer) do
    scan(buffer, [], %{checksum_errors: 0, dropped_bytes: 0})
  end

  @doc "Fletcher-16 as implemented by `BridgeBase::fletcher16`."
  @spec fletcher16(binary()) :: 0..0xFFFF
  def fletcher16(data) when is_binary(data) do
    {sum1, sum2} =
      data
      |> :binary.bin_to_list()
      |> Enum.reduce({0, 0}, fn byte, {sum1, sum2} ->
        sum1 = rem(sum1 + byte, 255)
        {sum1, rem(sum2 + sum1, 255)}
      end)

    sum2 <<< 8 ||| sum1
  end

  defp scan(buffer, acc, stats) do
    case :binary.match(buffer, @magic) do
      :nomatch ->
        rest = trailing_partial_magic(buffer)
        {Enum.reverse(acc), rest, drop(stats, byte_size(buffer) - byte_size(rest))}

      {0, _} ->
        decode_at(buffer, acc, stats)

      {pos, _} ->
        <<_skipped::binary-size(^pos), rest::binary>> = buffer
        scan(rest, acc, drop(stats, pos))
    end
  end

  defp decode_at(<<@magic_hi, @magic_lo, len::big-16, rest::binary>> = buffer, acc, stats) do
    cond do
      len == 0 or len > @max_packet ->
        resync(buffer, acc, stats)

      byte_size(rest) < len + 2 ->
        {Enum.reverse(acc), buffer, stats}

      true ->
        <<packet::binary-size(^len), checksum::big-16, tail::binary>> = rest

        if fletcher16(packet) == checksum do
          scan(tail, [packet | acc], stats)
        else
          resync(buffer, acc, %{stats | checksum_errors: stats.checksum_errors + 1})
        end
    end
  end

  # Magic found but the length field hasn't arrived yet.
  defp decode_at(buffer, acc, stats), do: {Enum.reverse(acc), buffer, stats}

  # Advance a single byte rather than past the whole magic, so a genuine frame
  # starting inside a corrupt one is still recovered.
  defp resync(<<_dropped, rest::binary>>, acc, stats), do: scan(rest, acc, drop(stats, 1))

  defp trailing_partial_magic(<<>>), do: <<>>

  defp trailing_partial_magic(buffer) do
    if :binary.last(buffer) == @magic_hi, do: <<@magic_hi>>, else: <<>>
  end

  defp drop(stats, 0), do: stats
  defp drop(stats, n), do: %{stats | dropped_bytes: stats.dropped_bytes + n}
end
