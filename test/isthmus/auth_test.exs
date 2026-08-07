defmodule Isthmus.AuthTest do
  use ExUnit.Case, async: true

  alias Isthmus.Auth
  alias Isthmus.Nostr.Crypto
  alias Isthmus.Nostr.Event

  test "rejects wrong kind" do
    challenge = Auth.create_challenge("isthmus")
    {sk, pk} = Secp256k1.keypair(:xonly)
    sk = Crypto.normalize_seckey(sk)

    event =
      sign_event(sk, pk, %{
        kind: 1,
        content: challenge.message,
        tags: [["method", "LOGIN"]]
      })

    assert {:error, :invalid_kind} = Auth.verify_signed_event(event)
  end

  test "accepts valid NIP-07 login event" do
    challenge = Auth.create_challenge("isthmus")
    {sk, pk} = Secp256k1.keypair(:xonly)
    sk = Crypto.normalize_seckey(sk)

    event =
      sign_event(sk, pk, %{
        kind: 27_235,
        content: challenge.message,
        tags: [["u", "http://localhost"], ["method", "LOGIN"]]
      })

    assert {:ok, %{token: token, pubkey_hex: hex}} = Auth.verify_signed_event(event)
    assert hex == Base.encode16(pk, case: :lower)
    assert {:ok, _} = Auth.consume_login_token(token)
  end

  defp sign_event(sk, pk, attrs) do
    pubkey = Base.encode16(pk, case: :lower)
    created_at = System.system_time(:second)

    id =
      Event.compute_id(%{
        pubkey: pubkey,
        created_at: created_at,
        kind: attrs.kind,
        tags: attrs.tags,
        content: attrs.content
      })

    sig = Secp256k1.schnorr_sign(Base.decode16!(id, case: :lower), sk)

    %{
      "id" => id,
      "pubkey" => pubkey,
      "created_at" => created_at,
      "kind" => attrs.kind,
      "tags" => attrs.tags,
      "content" => attrs.content,
      "sig" => Base.encode16(sig, case: :lower)
    }
  end
end
