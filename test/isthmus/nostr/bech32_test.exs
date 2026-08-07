defmodule Isthmus.Nostr.Bech32Test do
  use ExUnit.Case, async: true

  alias Isthmus.Nostr.Bech32

  test "round-trips npub" do
    {_, pubkey} = Secp256k1.keypair(:xonly)
    npub = Bech32.encode_npub(pubkey)
    assert String.starts_with?(npub, "npub1")
    assert {:ok, "npub", ^pubkey} = Bech32.decode(npub)
  end
end
