defmodule Isthmus.Networks.Meshtastic.Protobuf do
  @moduledoc """
  Minimal protobuf3 encoder/decoder for the Meshtastic serial subset.

  Unknown fields are skipped on decode. Default proto3 zeros are still encoded
  when the caller asks — channel index 0 is PRIMARY and must be sent.
  """
  import Bitwise

  @wire_varint 0
  @wire_64 1
  @wire_bytes 2
  @wire_32 5

  def encode_varint(n) when is_integer(n) and n >= 0, do: do_varint(n)

  def field_key(field, wire) when is_integer(field) and wire in 0..7 do
    encode_varint(field <<< 3 ||| wire)
  end

  def encode_varint_field(field, value) when is_integer(value) and value >= 0 do
    field_key(field, @wire_varint) <> encode_varint(value)
  end

  def encode_bool_field(field, true), do: encode_varint_field(field, 1)
  def encode_bool_field(_field, false), do: <<>>

  @doc "Encode a bool even when false (needed so LoRa `use_preset` / `tx_enabled` are not dropped)."
  def encode_bool_explicit(field, true), do: encode_varint_field(field, 1)
  def encode_bool_explicit(field, false), do: encode_varint_field(field, 0)

  @doc "Interpret a protobuf wire32 integer as IEEE-754 little-endian float."
  def as_float32(n) when is_integer(n) do
    <<f::little-float-32>> = <<n::little-unsigned-32>>
    f
  end

  def as_float32(_), do: 0.0

  def encode_bytes_field(_field, <<>>), do: <<>>

  def encode_bytes_field(field, value) when is_binary(value) do
    encode_bytes_explicit(field, value)
  end

  @doc "Encode bytes even when empty (needed so a disabled channel clears name/PSK)."
  def encode_bytes_explicit(field, value) when is_binary(value) do
    field_key(field, @wire_bytes) <> encode_varint(byte_size(value)) <> value
  end

  def encode_message_field(field, value) when is_binary(value) do
    field_key(field, @wire_bytes) <> encode_varint(byte_size(value)) <> value
  end

  def encode_fixed32_field(field, value) when is_integer(value) do
    field_key(field, @wire_32) <> <<value::little-unsigned-32>>
  end

  def encode_float_field(field, value) when is_number(value) do
    field_key(field, @wire_32) <> <<value::little-float-32>>
  end

  @doc "Decode a protobuf message into `{field, value}` pairs. Bytes stay binary."
  def decode(binary) when is_binary(binary), do: decode_fields(binary, [])

  def field(fields, number) when is_list(fields) and is_integer(number) do
    case List.keyfind(fields, number, 0) do
      {^number, value} -> value
      nil -> nil
    end
  end

  def fields(fields, number) when is_list(fields) and is_integer(number) do
    for {^number, value} <- fields, do: value
  end

  def varint(fields, number, default \\ 0) do
    case field(fields, number) do
      n when is_integer(n) -> n
      _ -> default
    end
  end

  def bytes(fields, number, default \\ nil) do
    case field(fields, number) do
      bin when is_binary(bin) -> bin
      _ -> default
    end
  end

  def nested(fields, number) do
    case bytes(fields, number) do
      bin when is_binary(bin) -> decode(bin)
      _ -> []
    end
  end

  defp do_varint(n) when n < 128, do: <<n>>
  defp do_varint(n), do: <<(n &&& 0x7F) ||| 0x80, do_varint(n >>> 7)::binary>>

  defp decode_fields(<<>>, acc), do: Enum.reverse(acc)

  defp decode_fields(rest, acc) do
    case take_varint(rest) do
      {:ok, key, rest} ->
        field = key >>> 3
        wire = key &&& 7

        case take_value(wire, rest) do
          {:ok, value, rest} -> decode_fields(rest, [{field, value} | acc])
          :error -> Enum.reverse(acc)
        end

      :error ->
        Enum.reverse(acc)
    end
  end

  defp take_value(@wire_varint, rest) do
    case take_varint(rest) do
      {:ok, n, rest} -> {:ok, n, rest}
      :error -> :error
    end
  end

  defp take_value(@wire_64, <<value::little-unsigned-64, rest::binary>>), do: {:ok, value, rest}

  defp take_value(@wire_bytes, rest) do
    case take_varint(rest) do
      {:ok, len, rest} when byte_size(rest) >= len ->
        <<value::binary-size(^len), rest::binary>> = rest
        {:ok, value, rest}

      _ ->
        :error
    end
  end

  defp take_value(@wire_32, <<value::little-unsigned-32, rest::binary>>), do: {:ok, value, rest}
  defp take_value(_, _), do: :error

  defp take_varint(bin), do: take_varint(bin, 0, 0)

  defp take_varint(<<>>, _acc, _shift), do: :error

  defp take_varint(<<byte, rest::binary>>, acc, shift) when shift <= 63 do
    acc = acc ||| (byte &&& 0x7F) <<< shift

    if (byte &&& 0x80) == 0 do
      {:ok, acc, rest}
    else
      take_varint(rest, acc, shift + 7)
    end
  end

  defp take_varint(_, _, _), do: :error
end
