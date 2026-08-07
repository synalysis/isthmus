defmodule Isthmus.Nostr.EventTest do
  use ExUnit.Case, async: true

  alias Isthmus.Nostr.Event

  test "signs and verifies a nostr event" do
    {seckey, pubkey} = Secp256k1.keypair(:xonly)
    pubkey_hex = Base.encode16(pubkey, case: :lower)

    created_at = System.system_time(:second)
    kind = 1
    tags = []
    content = "hello isthmus"

    id =
      Event.compute_id(%{
        pubkey: pubkey_hex,
        created_at: created_at,
        kind: kind,
        tags: tags,
        content: content
      })

    id_bin = Base.decode16!(id, case: :lower)
    sig = Secp256k1.schnorr_sign(id_bin, seckey)

    event = %{
      "id" => id,
      "pubkey" => pubkey_hex,
      "created_at" => created_at,
      "kind" => kind,
      "tags" => tags,
      "content" => content,
      "sig" => Base.encode16(sig, case: :lower)
    }

    assert {:ok, ^pubkey_hex} = Event.verify(event)
  end
end
