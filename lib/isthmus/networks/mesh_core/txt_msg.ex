defmodule Isthmus.Networks.MeshCore.TxtMsg do
  @moduledoc "MeshCore encrypted TXT_MSG compose/decrypt and ACK checksums."

  alias Isthmus.Networks.MeshCore.Crypto
  alias Isthmus.Networks.MeshCore.Packet

  @doc """
  Build a flood or direct TXT_MSG packet blob.

  `path` / `path_len` used for direct; for flood pass `0` / `<<>>`.
  """
  def build(opts) do
    seed = Keyword.fetch!(opts, :seed)
    our_pub = Keyword.fetch!(opts, :our_pub)
    dest_pub = Keyword.fetch!(opts, :dest_pub)
    text = Keyword.fetch!(opts, :text) |> to_string()
    attempt = Keyword.get(opts, :attempt, 0)
    timestamp = Keyword.get(opts, :timestamp) || System.system_time(:second)
    route = Keyword.get(opts, :route, Packet.route_flood())
    path_len = Keyword.get(opts, :path_len, 0)
    path = Keyword.get(opts, :path, <<>>)

    secret = Crypto.shared_secret(seed, dest_pub)
    plaintext = compose_plaintext(timestamp, attempt, text)
    body = Crypto.encrypt_then_mac(secret, plaintext)

    payload = Crypto.node_hash(dest_pub) <> Crypto.node_hash(our_pub) <> body
    expected_ack = ack_crc32(plaintext, byte_size(text), our_pub)
    expected_ack_bytes = ack_crc32_bytes(plaintext, byte_size(text), our_pub)

    packet =
      Packet.build(route, Packet.type_txt_msg(), path_len, path, payload)
      |> Packet.encode()

    {:ok,
     %{
       packet: packet,
       expected_ack: expected_ack,
       expected_ack_bytes: expected_ack_bytes,
       timestamp: timestamp,
       secret: secret
     }}
  end

  def decrypt(seed, our_pub, packet_or_map, peer_pub_candidates)

  def decrypt(seed, our_pub, packet, peers) when is_binary(packet) do
    case Packet.decode(packet) do
      {:ok, map} -> decrypt(seed, our_pub, map, peers)
      err -> err
    end
  end

  def decrypt(seed, our_pub, %{payload_type: type, payload: payload} = pkt, peers)
      when type == 2 and is_list(peers) do
    our_hash = Crypto.node_hash(our_pub)

    case payload do
      <<dest_hash::binary-1, src_hash::binary-1, wire::binary>> ->
        if dest_hash != our_hash do
          {:error, :not_for_us}
        else
          try_peers(seed, src_hash, wire, pkt, peers)
        end

      _ ->
        {:error, :invalid_payload}
    end
  end

  def decrypt(_, _, _, _), do: {:error, :not_txt_msg}

  @doc "ACK bytes (6) for a decrypted plain TXT_MSG, matching BaseChatMesh."
  def ack_bytes(plaintext, sender_pub)
      when is_binary(plaintext) and byte_size(sender_pub) == 32 do
    text = plaintext_text(plaintext)
    text_len = byte_size(text)
    data_len = 5 + text_len
    prefix = binary_part(plaintext, 0, min(byte_size(plaintext), data_len))
    <<crc::binary-4, _::binary>> = :crypto.hash(:sha256, prefix <> sender_pub)

    ext =
      if byte_size(plaintext) > data_len + 1 do
        :binary.at(plaintext, data_len + 1)
      else
        0
      end

    crc <> <<ext, :crypto.strong_rand_bytes(1)::binary>>
  end

  @doc "First 4 ACK bytes as little-endian uint32 (sender's expected_ack table key)."
  def ack_crc32(plaintext, text_len, our_pub) do
    prefix = binary_part(plaintext, 0, 5 + text_len)
    <<crc::little-32, _::binary>> = :crypto.hash(:sha256, prefix <> our_pub)
    crc
  end

  def ack_crc32_bytes(plaintext, text_len, our_pub) do
    prefix = binary_part(plaintext, 0, 5 + text_len)
    :crypto.hash(:sha256, prefix <> our_pub) |> binary_part(0, 4)
  end

  defp try_peers(seed, src_hash, wire, pkt, peers) do
    peers
    |> Enum.filter(fn pub -> Crypto.node_hash(pub) == src_hash end)
    |> Enum.find_value(fn pub ->
      secret = Crypto.shared_secret(seed, pub)

      case Crypto.mac_then_decrypt(secret, wire) do
        {:ok, plaintext} ->
          text = plaintext_text(plaintext)

          {:ok,
           %{
             from_pub: pub,
             text: text,
             plaintext: plaintext,
             timestamp: plaintext_timestamp(plaintext),
             secret: secret,
             packet: pkt,
             ack: ack_bytes(plaintext, pub)
           }}

        :error ->
          nil
      end
    end) || {:error, :decrypt_failed}
  end

  defp compose_plaintext(timestamp, attempt, text) do
    flags = Bitwise.band(attempt, 3)
    # Firmware encrypts timestamp‖flags‖text (no null) for attempt <= 3.
    base = <<timestamp::little-32, flags, text::binary>>

    if attempt > 3 do
      base <> <<0, attempt>>
    else
      base
    end
  end

  defp plaintext_timestamp(<<ts::little-32, _::binary>>), do: ts
  defp plaintext_timestamp(_), do: 0

  defp plaintext_text(<<_::little-32, _flags, rest::binary>>) do
    case :binary.split(rest, <<0>>) do
      [text | _] -> text
      _ -> rest
    end
  end

  defp plaintext_text(_), do: ""
end
