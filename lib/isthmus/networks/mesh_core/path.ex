defmodule Isthmus.Networks.MeshCore.Path do
  @moduledoc "MeshCore PATH return (createPathReturn) encode/decode."

  alias Isthmus.Networks.MeshCore.Crypto
  alias Isthmus.Networks.MeshCore.Packet

  @doc """
  Build a flood PATH return packet.

  `path` / `path_len` are the inbound flood path (same bytes peers store as out_path).
  `extra` is typically 6-byte ACK data for bundled ACK.
  """
  def build_return(opts) do
    seed = Keyword.fetch!(opts, :seed)
    our_pub = Keyword.fetch!(opts, :our_pub)
    dest_pub = Keyword.fetch!(opts, :dest_pub)
    path = Keyword.get(opts, :path, <<>>)
    path_len = Keyword.get(opts, :path_len, Packet.encode_path_len(byte_size(path)))
    extra_type = Keyword.get(opts, :extra_type, Packet.type_ack())
    extra = Keyword.get(opts, :extra, <<>>)

    secret = Crypto.shared_secret(seed, dest_pub)
    path_bytes = Packet.path_byte_len(path_len)
    path = binary_part(path <> :binary.copy(<<0>>, path_bytes), 0, path_bytes)

    plaintext =
      if extra == <<>> do
        <<path_len, path::binary, 0xFF, :crypto.strong_rand_bytes(4)::binary>>
      else
        <<path_len, path::binary, extra_type, extra::binary>>
      end

    body = Crypto.encrypt_then_mac(secret, plaintext)
    payload = Crypto.node_hash(dest_pub) <> Crypto.node_hash(our_pub) <> body

    Packet.build(Packet.route_flood(), Packet.type_path(), 0, <<>>, payload)
    |> Packet.encode()
  end

  @doc """
  Decrypt a PATH packet addressed to us. Returns peer out_path and optional bundled ACK.
  """
  def decrypt(seed, our_pub, packet_or_map, peer_pub)

  def decrypt(seed, our_pub, packet, peer_pub) when is_binary(packet) do
    case Packet.decode(packet) do
      {:ok, map} -> decrypt(seed, our_pub, map, peer_pub)
      err -> err
    end
  end

  def decrypt(seed, our_pub, %{payload_type: type, payload: payload}, peer_pub)
      when type == 8 and byte_size(peer_pub) == 32 do
    our_hash = Crypto.node_hash(our_pub)

    case payload do
      <<dest_hash::binary-1, src_hash::binary-1, wire::binary>> ->
        cond do
          dest_hash != our_hash ->
            {:error, :not_for_us}

          Crypto.node_hash(peer_pub) != src_hash ->
            {:error, :src_mismatch}

          true ->
            secret = Crypto.shared_secret(seed, peer_pub)

            with {:ok, plaintext} <- Crypto.mac_then_decrypt(secret, wire) do
              parse_plaintext(plaintext, peer_pub, secret)
            else
              :error -> {:error, :decrypt_failed}
            end
        end

      _ ->
        {:error, :invalid_payload}
    end
  end

  def decrypt(_, _, _, _), do: {:error, :not_path}

  def build_ack_packet(ack) when is_binary(ack) and byte_size(ack) >= 4 do
    Packet.build(Packet.route_direct(), Packet.type_ack(), 0, <<>>, binary_part(ack, 0, 4))
    |> Packet.encode()
  end

  defp parse_plaintext(<<path_len, rest::binary>>, peer_pub, secret) do
    path_bytes = Packet.path_byte_len(path_len)

    if byte_size(rest) >= path_bytes + 1 do
      <<path::binary-size(^path_bytes), extra_type, extra::binary>> = rest
      extra_type = Bitwise.band(extra_type, 0x0F)

      {:ok,
       %{
         from_pub: peer_pub,
         out_path: path,
         out_path_len: path_len,
         extra_type: extra_type,
         extra: extra,
         secret: secret,
         ack_crc:
           if(extra_type == Packet.type_ack() and byte_size(extra) >= 4,
             do: :binary.decode_unsigned(binary_part(extra, 0, 4), :little),
             else: nil
           )
       }}
    else
      {:error, :invalid_path_plaintext}
    end
  end

  defp parse_plaintext(_, _, _), do: {:error, :invalid_path_plaintext}
end
