defmodule Isthmus.Gateway.TranslatorRoutingTest do
  use Isthmus.DataCase, async: false

  alias Isthmus.Gateway
  alias Isthmus.Gateway.Message
  alias Isthmus.Gateway.Translator
  alias Isthmus.Registrations

  test "meshcore @token resolves bridge group and strips token from body" do
    owner = owner_hex()
    assert {:ok, group} = Registrations.create_bridge_group(owner, %{display_name: "Token Camp"})

    mc = String.duplicate("aa", 32)
    {_sk, pk} = Secp256k1.keypair(:xonly)
    nostr = Base.encode16(pk, case: :lower)

    assert {:ok, _} = Registrations.attach_member(group, "meshcore", mc)
    assert {:ok, _} = Registrations.attach_member(group, "nostr", nostr)

    before = Gateway.stats().total

    Translator.ingest(%Message{
      from_network: :meshcore,
      from_ref: String.duplicate("bb", 32),
      to_ref: nil,
      body: "@token-camp hello across the bridge",
      external_id: "tok-#{System.unique_integer([:positive])}",
      meta: %{}
    })

    _ = :sys.get_state(Translator)

    logs = Gateway.list_forward_log(20)
    assert Enum.any?(logs, &(&1.registration_group_id == group.id))
    assert Gateway.stats().total >= before
  end

  test "meshcore primary from_ref resolves registration without @token" do
    owner = owner_hex()
    mc = String.duplicate("cc", 32)

    assert {:ok, group} =
             Registrations.register_meshcore_primary(owner, mc, %{
               display_name: "Primary Radio",
               created_by: "admin"
             })

    Translator.ingest(%Message{
      from_network: :meshcore,
      from_ref: mc,
      to_ref: nil,
      body: "ping from primary",
      external_id: "pri-#{System.unique_integer([:positive])}",
      meta: %{}
    })

    _ = :sys.get_state(Translator)

    assert Enum.any?(Gateway.list_forward_log(20), &(&1.registration_group_id == group.id))
  end

  test "meshcore channel ingress resolves linked bridge group" do
    owner = owner_hex()

    assert {:ok, group} =
             Registrations.create_bridge_group(owner, %{display_name: "Radio Channel"})

    secret = String.duplicate("ef", 16)
    assert {:ok, group} = Registrations.link_meshcore_channel(group, 4, secret)

    {_sk, pk} = Secp256k1.keypair(:xonly)
    nostr = Base.encode16(pk, case: :lower)
    assert {:ok, _} = Registrations.attach_member(group, "nostr", nostr)

    Translator.ingest(%Message{
      from_network: :meshcore,
      from_ref: nil,
      body: "channel broadcast",
      external_id: "ch-#{System.unique_integer([:positive])}",
      meta: %{"meshcore_channel" => 4}
    })

    _ = :sys.get_state(Translator)

    assert Enum.any?(Gateway.list_forward_log(20), &(&1.registration_group_id == group.id))
  end

  test "nostr subject in meta resolves bridge group over author alone" do
    owner = owner_hex()

    assert {:ok, group} =
             Registrations.create_bridge_group(owner, %{display_name: "Subject Lobby"})

    mc = String.duplicate("dd", 32)
    {_sk, pk} = Secp256k1.keypair(:xonly)
    nostr = Base.encode16(pk, case: :lower)

    assert {:ok, _} = Registrations.attach_member(group, "meshcore", mc)
    assert {:ok, _} = Registrations.attach_member(group, "nostr", nostr)

    # Author is not a leg — routing must use NIP-17 subject.
    {_sk2, stranger_pk} = Secp256k1.keypair(:xonly)
    stranger = Base.encode16(stranger_pk, case: :lower)

    Translator.ingest(%Message{
      from_network: :nostr,
      from_ref: stranger,
      to_ref: owner,
      body: "reply via subject room",
      external_id: "subj-#{System.unique_integer([:positive])}",
      meta: %{"kind" => 1059, "subject" => Registrations.nostr_room_subject(group)}
    })

    _ = :sys.get_state(Translator)

    assert Enum.any?(Gateway.list_forward_log(20), &(&1.registration_group_id == group.id))
  end

  test "nostr to_ref proxy routes without subject" do
    owner = owner_hex()

    assert {:ok, group} =
             Registrations.create_bridge_group(owner, %{display_name: "Proxy Lobby"})

    mc = String.duplicate("ee", 32)
    {_sk, pk} = Secp256k1.keypair(:xonly)
    nostr = Base.encode16(pk, case: :lower)

    assert {:ok, _} = Registrations.attach_member(group, "meshcore", mc)
    assert {:ok, _} = Registrations.attach_member(group, "nostr", nostr)
    assert {:ok, group} = Registrations.ensure_nostr_proxy(group)
    proxy = Registrations.nostr_proxy_leg(group)

    {_sk2, stranger_pk} = Secp256k1.keypair(:xonly)
    stranger = Base.encode16(stranger_pk, case: :lower)

    Translator.ingest(%Message{
      from_network: :nostr,
      from_ref: stranger,
      to_ref: proxy.identity_ref,
      body: "reply to group proxy",
      external_id: "proxy-#{System.unique_integer([:positive])}",
      meta: %{"kind" => 1059}
    })

    _ = :sys.get_state(Translator)

    assert Enum.any?(Gateway.list_forward_log(20), &(&1.registration_group_id == group.id))
  end

  defp owner_hex do
    {_seckey, pubkey} = Secp256k1.keypair(:xonly)
    Base.encode16(pubkey, case: :lower)
  end
end
