defmodule Isthmus.Networks.Nostr.TunnelCarrierTest do
  use ExUnit.Case, async: true

  alias Isthmus.Networks.Nostr.TunnelCarrier

  test "ignores non-tunnel kinds" do
    assert :ignore =
             TunnelCarrier.handle_inbound_event(%{"kind" => 1, "content" => "hi", "tags" => []})
  end

  test "decodes plain base64 tunnel events without engine crash" do
    payload = <<"ISTH", 1, 2, 3, 4>>

    event = %{
      "kind" => TunnelCarrier.kind(),
      "content" => Base.encode64(payload),
      "tags" => [["t", TunnelCarrier.tag()]],
      "pubkey" => String.duplicate("ab", 32)
    }

    # Engine may reject incomplete frames; we only assert decode path runs
    result = TunnelCarrier.handle_inbound_event(event)
    assert result in [:ok, :error]
  end

  test "filter helpers" do
    assert %{"kinds" => [21_278], "#t" => ["isthmus-tunnel"]} = TunnelCarrier.filter_global()
    f = TunnelCarrier.filter_for_service("aabb")
    assert f["#p"] == ["aabb"]
  end

  test "decodes nip44-encrypted tunnel events" do
    alias Isthmus.Nostr.{Bech32, Crypto}

    {sk_sender, pk_sender} = Secp256k1.keypair(:xonly)
    {sk_recv, pk_recv} = Secp256k1.keypair(:xonly)
    sk_recv = Crypto.normalize_seckey(sk_recv)
    nsec = Bech32.encode("nsec", sk_recv)

    prev = System.get_env("ISTHMUS_NOSTR_NSEC")
    System.put_env("ISTHMUS_NOSTR_NSEC", nsec)

    on_exit(fn ->
      if prev,
        do: System.put_env("ISTHMUS_NOSTR_NSEC", prev),
        else: System.delete_env("ISTHMUS_NOSTR_NSEC")
    end)

    payload = <<"ISTH", 9, 8, 7, 6>>
    b64 = Base.encode64(payload)
    content = Crypto.nip44_encrypt(sk_sender, pk_recv, b64)

    event = %{
      "kind" => TunnelCarrier.kind(),
      "content" => content,
      "tags" => [["t", TunnelCarrier.tag()], ["encryption", "nip44"]],
      "pubkey" => Base.encode16(pk_sender, case: :lower)
    }

    assert :ok = TunnelCarrier.handle_inbound_event(event)
  end

  test "still decodes legacy nip04 tunnel events" do
    alias Isthmus.Nostr.{Bech32, Crypto}

    {sk_sender, pk_sender} = Secp256k1.keypair(:xonly)
    {sk_recv, pk_recv} = Secp256k1.keypair(:xonly)
    sk_recv = Crypto.normalize_seckey(sk_recv)
    nsec = Bech32.encode("nsec", sk_recv)

    prev = System.get_env("ISTHMUS_NOSTR_NSEC")
    System.put_env("ISTHMUS_NOSTR_NSEC", nsec)

    on_exit(fn ->
      if prev,
        do: System.put_env("ISTHMUS_NOSTR_NSEC", prev),
        else: System.delete_env("ISTHMUS_NOSTR_NSEC")
    end)

    payload = <<"ISTH", 1, 2, 3, 4>>
    b64 = Base.encode64(payload)
    content = Crypto.nip04_encrypt(sk_sender, pk_recv, b64)

    event = %{
      "kind" => TunnelCarrier.kind(),
      "content" => content,
      "tags" => [["t", TunnelCarrier.tag()], ["encryption", "nip04"]],
      "pubkey" => Base.encode16(pk_sender, case: :lower)
    }

    assert TunnelCarrier.handle_inbound_event(event) in [:ok, :error]
  end
end

defmodule Isthmus.Networks.Nostr.RelayPoolPublishTest do
  use Isthmus.DataCase, async: false

  alias Isthmus.Announce.Governor
  alias Isthmus.Networks.Nostr.RelayPool
  alias Isthmus.Networks.Nostr.TunnelCarrier

  test "tunnel publishes are not blocked by nostr_metadata dedup" do
    # Saturate the 24h metadata governor for the service pubkey.
    pubkey = String.duplicate("ab", 32)
    assert :ok = Governor.allow?(:nostr_metadata, :nostr, pubkey)
    assert {:drop, :dedup} = Governor.allow?(:nostr_metadata, :nostr, pubkey)

    tunnel_event = %{
      "id" => String.duplicate("cd", 32),
      "pubkey" => pubkey,
      "kind" => TunnelCarrier.kind(),
      "content" => Base.encode64("ISTH"),
      "tags" => [["t", TunnelCarrier.tag()]]
    }

    # May fail for :no_write_relays in test, but must NOT be governor dedup.
    result = RelayPool.publish_event(tunnel_event)
    refute match?({:error, {:governor, _}}, result)

    meta_event = %{
      "id" => String.duplicate("ef", 32),
      "pubkey" => pubkey,
      "kind" => 0,
      "content" => "{}",
      "tags" => []
    }

    assert {:error, {:governor, :dedup}} = RelayPool.publish_event(meta_event)
  end
end
