defmodule Isthmus.Networks.MeshCore.Packet do
  @moduledoc "MeshCore wire packet encode/decode (v1)."

  @route_transport_flood 0x00
  @route_flood 0x01
  @route_direct 0x02
  @route_transport_direct 0x03

  @type_txt_msg 0x02
  @type_ack 0x03
  @type_advert 0x04
  @type_path 0x08

  @max_path 64
  @max_payload 184

  def route_flood, do: @route_flood
  def route_direct, do: @route_direct
  def type_txt_msg, do: @type_txt_msg
  def type_ack, do: @type_ack
  def type_advert, do: @type_advert
  def type_path, do: @type_path

  @type t :: %{
          route: non_neg_integer(),
          payload_type: non_neg_integer(),
          version: non_neg_integer(),
          transport_codes: {non_neg_integer(), non_neg_integer()} | nil,
          path_len: byte(),
          path: binary(),
          payload: binary()
        }

  def encode(%{
        route: route,
        payload_type: type,
        version: version,
        transport_codes: codes,
        path_len: path_len,
        path: path,
        payload: payload
      })
      when byte_size(payload) <= @max_payload do
    header = Bitwise.bor(Bitwise.bor(route, Bitwise.bsl(type, 2)), Bitwise.bsl(version, 6))
    path_bytes = path_byte_len(path_len)
    path = binary_part(path <> :binary.copy(<<0>>, path_bytes), 0, path_bytes)

    transport =
      case codes do
        {a, b} -> <<a::little-16, b::little-16>>
        nil -> <<>>
      end

    <<header, transport::binary, path_len, path::binary, payload::binary>>
  end

  def decode(<<header, rest::binary>>) do
    route = Bitwise.band(header, 0x03)
    type = Bitwise.band(Bitwise.bsr(header, 2), 0x0F)
    version = Bitwise.band(Bitwise.bsr(header, 6), 0x03)

    with {:ok, codes, rest} <- take_transport(route, rest),
         {:ok, path_len, path, payload} <- take_path_payload(rest) do
      {:ok,
       %{
         route: route,
         payload_type: type,
         version: version,
         transport_codes: codes,
         path_len: path_len,
         path: path,
         payload: payload
       }}
    end
  end

  def decode(_), do: {:error, :invalid_packet}

  def flood?(%{route: r}), do: r in [@route_flood, @route_transport_flood]
  def direct?(%{route: r}), do: r in [@route_direct, @route_transport_direct]

  def build(route, type, path_len, path, payload, opts \\ []) do
    %{
      route: route,
      payload_type: type,
      version: Keyword.get(opts, :version, 0),
      transport_codes: Keyword.get(opts, :transport_codes),
      path_len: path_len,
      path: path || <<>>,
      payload: payload
    }
  end

  def packet_hash(%{payload_type: type, path_len: path_len, payload: payload}) do
    pre =
      if type == 0x09 do
        <<type, path_len>>
      else
        <<type>>
      end

    :crypto.hash(:sha256, pre <> payload) |> binary_part(0, 8)
  end

  defp take_transport(route, rest)
       when route in [@route_transport_flood, @route_transport_direct] do
    case rest do
      <<a::little-16, b::little-16, rest::binary>> -> {:ok, {a, b}, rest}
      _ -> {:error, :truncated}
    end
  end

  defp take_transport(_route, rest), do: {:ok, nil, rest}

  defp take_path_payload(<<path_len, rest::binary>>) do
    bl = path_byte_len(path_len)

    if bl > @max_path or byte_size(rest) < bl do
      {:error, :bad_path}
    else
      <<path::binary-size(^bl), payload::binary>> = rest

      if payload == <<>> or byte_size(payload) > @max_payload do
        {:error, :bad_payload}
      else
        {:ok, path_len, path, payload}
      end
    end
  end

  defp take_path_payload(_), do: {:error, :truncated}

  def path_byte_len(path_len) do
    hash_count = Bitwise.band(path_len, 63)
    hash_size = Bitwise.bsr(path_len, 6) + 1
    hash_count * hash_size
  end

  def encode_path_len(hop_count, hash_size \\ 1)
      when hop_count in 0..63 and hash_size in 1..3 do
    Bitwise.bor(hop_count, Bitwise.bsl(hash_size - 1, 6))
  end
end
