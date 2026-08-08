defmodule Isthmus.Networks.MeshCore.Crypto do
  @moduledoc """
  MeshCore identity crypto: Ed25519, Ed25519→X25519 ECDH, AES-128-ECB, HMAC-SHA256/2.

  Matches Nightcracker ed25519 + `Utils::encryptThenMAC` in MeshCore firmware.
  """

  @p 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFED
  @pub_key_size 32
  @mac_size 2
  @block_size 16
  @cipher_key_size 16

  @doc "Generate a MeshCore-compatible Ed25519 seed/pubkey, rejecting 0x00/0xFF hash prefixes."
  def generate_keypair do
    Enum.find_value(1..32, fn _ ->
      {pub, seed} = :crypto.generate_key(:eddsa, :ed25519)
      <<hash, _::binary>> = pub

      if hash in [0x00, 0xFF] do
        nil
      else
        {pub, seed}
      end
    end) || raise("unable to mint MeshCore keypair without reserved hash prefix")
  end

  def keypair_from_seed(seed) when byte_size(seed) == 32 do
    {pub, ^seed} = :crypto.generate_key(:eddsa, :ed25519, seed)
    {pub, seed}
  end

  def sign(seed, message) when byte_size(seed) == 32 and is_binary(message) do
    :crypto.sign(:eddsa, :none, message, [seed, :ed25519])
  end

  def verify(pub, message, sig)
      when byte_size(pub) == 32 and byte_size(sig) == 64 and is_binary(message) do
    :crypto.verify(:eddsa, :none, message, sig, [pub, :ed25519])
  end

  @doc """
  ECDH shared secret (32 bytes) between our seed and peer Ed25519 public key.

  Matches `LocalIdentity::calcSharedSecret` / `ed25519_key_exchange`.
  """
  def shared_secret(seed, peer_pub)
      when byte_size(seed) == 32 and byte_size(peer_pub) == @pub_key_size do
    scalar = expand_seed_scalar(seed)
    mont_pub = ed25519_to_x25519_public(peer_pub)
    :crypto.compute_key(:ecdh, mont_pub, scalar, :x25519)
  end

  @doc "AES-128-ECB + HMAC-SHA256 truncated to 2 bytes (`encryptThenMAC`)."
  def encrypt_then_mac(shared_secret, plaintext)
      when byte_size(shared_secret) == 32 and is_binary(plaintext) do
    ct = aes_ecb_encrypt(binary_part(shared_secret, 0, @cipher_key_size), plaintext)
    mac = hmac_trunc(shared_secret, ct)
    mac <> ct
  end

  @doc "`MACThenDecrypt`. Returns plaintext (zero-padded to block) or `:error`."
  def mac_then_decrypt(shared_secret, wire)
      when byte_size(shared_secret) == 32 and is_binary(wire) and byte_size(wire) > @mac_size do
    <<mac::binary-size(@mac_size), ct::binary>> = wire

    if hmac_trunc(shared_secret, ct) == mac and rem(byte_size(ct), @block_size) == 0 do
      {:ok, aes_ecb_decrypt(binary_part(shared_secret, 0, @cipher_key_size), ct)}
    else
      :error
    end
  end

  def mac_then_decrypt(_, _), do: :error

  def node_hash(<<h, _::binary>>), do: <<h>>
  def node_hash(_), do: <<0>>

  defp expand_seed_scalar(seed) do
    <<h0::binary-32, _::binary>> = :crypto.hash(:sha512, seed)
    <<b0, mid::binary-30, b31>> = h0
    b0 = Bitwise.band(b0, 248)
    b31 = Bitwise.bor(Bitwise.band(b31, 63), 64)
    <<b0, mid::binary, b31>>
  end

  defp ed25519_to_x25519_public(pub) do
    # Ed25519 pub encodes y with the x sign in bit 255 — clear it before the
    # Montgomery conversion (matches libsodium crypto_sign_ed25519_pk_to_curve25519).
    <<low::binary-31, last>> = pub
    y = fe_from_bytes(<<low::binary, Bitwise.band(last, 0x7F)>>)
    u = fe_mul(fe_add(y, 1), fe_inv(fe_sub(1, y)))
    fe_to_bytes(u)
  end

  defp fe_from_bytes(<<n::little-unsigned-256>>), do: fe_mod(n)
  defp fe_to_bytes(n), do: <<fe_mod(n)::little-unsigned-256>>

  defp fe_mod(a) do
    r = rem(a, @p)
    if r < 0, do: r + @p, else: r
  end

  defp fe_add(a, b), do: fe_mod(a + b)
  defp fe_sub(a, b), do: fe_mod(a - b)
  defp fe_mul(a, b), do: fe_mod(a * b)

  defp fe_inv(a) do
    bin =
      :crypto.mod_pow(
        :binary.encode_unsigned(a),
        :binary.encode_unsigned(@p - 2),
        :binary.encode_unsigned(@p)
      )

    :binary.decode_unsigned(bin)
  end

  defp aes_ecb_encrypt(key, plaintext) do
    padded = pad_block(plaintext)
    :crypto.crypto_one_time(:aes_128_ecb, key, padded, true)
  end

  defp aes_ecb_decrypt(key, ciphertext) do
    :crypto.crypto_one_time(:aes_128_ecb, key, ciphertext, false)
  end

  defp pad_block(data) do
    case rem(byte_size(data), @block_size) do
      0 -> data
      n -> data <> :binary.copy(<<0>>, @block_size - n)
    end
  end

  defp hmac_trunc(key, data) do
    :crypto.mac(:hmac, :sha256, key, data) |> binary_part(0, @mac_size)
  end
end
