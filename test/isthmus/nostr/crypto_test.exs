defmodule Isthmus.Nostr.CryptoTest do
  use ExUnit.Case, async: true

  alias Isthmus.Nostr.Crypto
  alias Isthmus.Nostr.Event

  test "nip04 encrypt/decrypt round-trip via nostr_lib" do
    {sk, pk} = Secp256k1.keypair(:xonly)
    {sk2, pk2} = Secp256k1.keypair(:xonly)

    ct = Crypto.nip04_encrypt(sk, pk2, "hello isthmus")
    assert {:ok, "hello isthmus"} = Crypto.nip04_decrypt(sk2, pk, ct)
  end

  test "nip44 encrypt/decrypt round-trip via nostr_lib" do
    {sk, pk} = Secp256k1.keypair(:xonly)
    {sk2, pk2} = Secp256k1.keypair(:xonly)

    ct = Crypto.nip44_encrypt(sk, pk2, "hello nip44")
    assert {:ok, "hello nip44"} = Crypto.nip44_decrypt(sk2, pk, ct)
  end

  test "nip04 works across odd-Y / even-Y keypairs after BIP340 normalize" do
    {sk_odd, sk_even} =
      Enum.reduce_while(1..200, {nil, nil}, fn _, {odd, even} ->
        {sk, _} = Secp256k1.keypair(:xonly)
        <<pref, _::binary>> = Secp256k1.pubkey(sk, :compressed)

        {odd, even} =
          cond do
            pref == 3 and is_nil(odd) -> {sk, even}
            pref == 2 and is_nil(even) -> {odd, sk}
            true -> {odd, even}
          end

        if odd && even, do: {:halt, {odd, even}}, else: {:cont, {odd, even}}
      end)

    pk_odd = Secp256k1.pubkey(sk_odd, :xonly)
    pk_even = Secp256k1.pubkey(sk_even, :xonly)

    ct = Crypto.nip04_encrypt(sk_odd, pk_even, "mixed parity")
    assert {:ok, "mixed parity"} = Crypto.nip04_decrypt(sk_even, pk_odd, ct)
  end

  test "normalize_seckey forces even-Y compressed pubkey" do
    {sk, pk} = Secp256k1.keypair(:xonly)
    sk_n = Crypto.normalize_seckey(sk)
    assert <<0x02, _::binary-32>> = Secp256k1.pubkey(sk_n, :compressed)
    assert Secp256k1.pubkey(sk_n, :xonly) == pk
  end

  test "NIP-17 dm_events round-trip through decrypt_inbound" do
    {sk, _pk} = Secp256k1.keypair(:xonly)
    {sk2, pk2} = Secp256k1.keypair(:xonly)
    hex = Base.encode16(pk2, case: :lower)

    assert {:ok, [event]} = Crypto.dm_events(sk, hex, "gift wrap ping")
    assert event["kind"] == 1059
    assert {:ok, "gift wrap ping", _sender, meta} = Crypto.decrypt_inbound(sk2, event)
    assert meta == %{}
  end

  test "NIP-17 dm_events preserve subject for group routing" do
    {sk, _pk} = Secp256k1.keypair(:xonly)
    {sk2, pk2} = Secp256k1.keypair(:xonly)
    hex = Base.encode16(pk2, case: :lower)

    assert {:ok, [event]} =
             Crypto.dm_events(sk, hex, "lobby ping", subject: "isthmus/lobby")

    assert {:ok, "lobby ping", _sender, %{subject: "isthmus/lobby"}} =
             Crypto.decrypt_inbound(sk2, event)
  end

  test "NIP-17 decrypt tolerates client rumors with mismatched id" do
    alias Nostr.Event.{GiftWrap, PrivateMessage, Seal}

    {sk_sender, pk_sender} = Secp256k1.keypair(:xonly)
    {sk_recv, pk_recv} = Secp256k1.keypair(:xonly)
    sk_sender_hex = Base.encode16(Crypto.normalize_seckey(sk_sender), case: :lower)
    sk_recv_hex = Base.encode16(Crypto.normalize_seckey(sk_recv), case: :lower)
    pk_sender_hex = Base.encode16(pk_sender, case: :lower)
    pk_recv_hex = Base.encode16(pk_recv, case: :lower)

    msg =
      PrivateMessage.create(pk_sender_hex, [pk_recv_hex], "Answer from Nostr",
        subject: "isthmus/lobby"
      )

    # Corrupt the rumor id the way some clients do — Seal.unwrap then returns
    # {:ok, {:error, :invalid_id, rumor}} and stock receive_dm crashes.
    bad_rumor = %{msg.rumor | id: String.duplicate("ab", 32)}
    seal = Seal.create(bad_rumor, sk_sender_hex, pk_recv_hex)
    wrap = GiftWrap.create(seal, pk_recv_hex)
    event = Isthmus.Nostr.Event.to_wire_map(wrap.event)

    assert {:ok, "Answer from Nostr", ^pk_sender_hex, %{subject: "isthmus/lobby"}} =
             Crypto.decrypt_inbound(sk_recv_hex, event)
  end

  test "legacy dm_event is verifiable kind 4" do
    import ExUnit.CaptureLog

    {sk, _pk} = Secp256k1.keypair(:xonly)
    {_sk2, pk2} = Secp256k1.keypair(:xonly)
    hex = Base.encode16(pk2, case: :lower)

    event =
      capture_log(fn ->
        send(self(), {:event, Crypto.dm_event(sk, hex, "ping")})
      end)
      |> then(fn _ ->
        assert_received {:event, ev}
        ev
      end)

    assert {:ok, _} = Event.verify(event)
    assert event["kind"] == 4
  end
end
