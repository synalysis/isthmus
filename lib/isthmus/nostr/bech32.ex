defmodule Isthmus.Nostr.Bech32 do
  @moduledoc """
  NIP-19 bech32 helpers for npub/nsec, wrapping `nostr_lib` / Bechamel.

  Keeps a binary-friendly API used across Isthmus auth and registration.
  """

  @doc "Encode 32-byte pubkey as npub."
  def encode_npub(pubkey) when is_binary(pubkey) and byte_size(pubkey) == 32 do
    encode("npub", pubkey)
  end

  @doc "Decode npub or nsec (optionally prefixed with nostr:) to `{hrp, raw_bytes}`."
  def decode("nostr:" <> rest), do: decode(rest)

  def decode(bech32) when is_binary(bech32) do
    case Bechamel.decode(String.downcase(bech32)) do
      {:ok, hrp, bin} when hrp in ["npub", "nsec"] and byte_size(bin) == 32 ->
        {:ok, hrp, bin}

      {:ok, _hrp, _bin} ->
        {:error, :invalid_bech32}

      {:error, _} ->
        {:error, :invalid_bech32}
    end
  end

  def encode(hrp, data) when is_binary(hrp) and is_binary(data) do
    Bechamel.encode(hrp, data)
  end
end
