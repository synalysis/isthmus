defmodule Isthmus.Networks.Meshtastic.MessageStore do
  @moduledoc """
  On-device Meshtastic chat log (`/Messages_default.msgs`).

  Screen-capable firmware keeps this flash file (default cap 100 on many
  S3/T-Deck builds). PhoneAPI does not dump it during `want_config`; Isthmus
  pulls it with XModem after the handshake.
  """

  @filename "/Messages_default.msgs"
  @max_text 220
  @record_size 4 + 4 + 1 + 4 + 1 + 1 + 1 + 2 + @max_text
  @type_broadcast 0

  def filename, do: @filename
  def record_size, do: @record_size

  @type parsed :: %{
          timestamp: integer(),
          sender: integer(),
          channel_idx: integer(),
          dest: integer(),
          type: :broadcast | :dm,
          body: String.t()
        }

  @doc "Parse a `Messages_*.msgs` blob. Unknown/truncated bytes are skipped."
  @spec parse(binary()) :: [parsed()]
  def parse(<<count, rest::binary>>) when count > 0 do
    take_records(rest, min(count, 255), [])
  end

  def parse(_), do: []

  defp take_records(_bin, 0, acc), do: Enum.reverse(acc)

  defp take_records(<<rec::binary-size(@record_size), rest::binary>>, n, acc) do
    take_records(rest, n - 1, [parse_record(rec) | acc])
  end

  defp take_records(_, _, acc), do: Enum.reverse(acc)

  defp parse_record(
         <<ts::little-32, sender::little-32, channel, dest::little-32, _boot, _ack, type,
           text_len::little-16, text::binary-size(@max_text)>>
       ) do
    len = min(text_len, @max_text)
    raw = binary_part(text, 0, len)

    body =
      raw
      |> String.trim_trailing(<<0>>)
      |> then(fn s -> if String.valid?(s), do: String.trim(s), else: "" end)

    %{
      timestamp: ts,
      sender: sender,
      channel_idx: channel,
      dest: dest,
      type: if(type == @type_broadcast, do: :broadcast, else: :dm),
      body: body
    }
  end
end
