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

  test "meshtastic channel ingress resolves linked bridge group" do
    owner = owner_hex()

    assert {:ok, group} =
             Registrations.create_bridge_group(owner, %{display_name: "Meshtastic Channel"})

    psk = String.duplicate("ab", 16)
    assert {:ok, group} = Registrations.link_meshtastic_channel(group, 2, psk)

    {_sk, pk} = Secp256k1.keypair(:xonly)
    nostr = Base.encode16(pk, case: :lower)
    assert {:ok, _} = Registrations.attach_member(group, "nostr", nostr)

    Translator.ingest(%Message{
      from_network: :meshtastic,
      from_ref: "deadbeef",
      body: "channel broadcast",
      external_id: "mt-ch-#{System.unique_integer([:positive])}",
      meta: %{"meshtastic_channel" => 2}
    })

    _ = :sys.get_state(Translator)

    assert Enum.any?(Gateway.list_forward_log(20), &(&1.registration_group_id == group.id))
  end

  test "meshtastic channel ingress is bound to radio identity" do
    owner = owner_hex()

    assert {:ok, group} =
             Registrations.create_bridge_group(owner, %{display_name: "Lobby"})

    psk = String.duplicate("ab", 16)

    assert {:ok, group} =
             Registrations.link_meshtastic_channel(group, 3, psk, device_id: "aabbccdd")

    {_sk, pk} = Secp256k1.keypair(:xonly)
    nostr = Base.encode16(pk, case: :lower)
    assert {:ok, _} = Registrations.attach_member(group, "nostr", nostr)

    Translator.ingest(%Message{
      from_network: :meshtastic,
      from_ref: "11223344",
      body: "other radio",
      external_id: "mt-other-#{System.unique_integer([:positive])}",
      meta: %{"meshtastic_channel" => 3, "radio_id" => "11223344"}
    })

    _ = :sys.get_state(Translator)
    refute Enum.any?(Gateway.list_forward_log(20), &(&1.registration_group_id == group.id))

    Translator.ingest(%Message{
      from_network: :meshtastic,
      from_ref: "deadbeef",
      body: "bound radio",
      external_id: "mt-bound-#{System.unique_integer([:positive])}",
      meta: %{"meshtastic_channel" => 3, "radio_id" => "aabbccdd"}
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

  test "nostr DMs to service identity are retained, not matched to groups" do
    {sk, _pk} = Secp256k1.keypair(:xonly)
    nsec = Isthmus.Nostr.Bech32.encode("nsec", sk)
    prev = System.get_env("ISTHMUS_NOSTR_NSEC")
    System.put_env("ISTHMUS_NOSTR_NSEC", nsec)

    on_exit(fn ->
      if prev,
        do: System.put_env("ISTHMUS_NOSTR_NSEC", prev),
        else: System.delete_env("ISTHMUS_NOSTR_NSEC")
    end)

    service_hex = Isthmus.Nostr.Crypto.service_pubkey_hex()
    assert is_binary(service_hex)

    owner = owner_hex()

    assert {:ok, group} =
             Registrations.create_bridge_group(owner, %{display_name: "Service Trap"})

    mc = String.duplicate("ff", 32)
    {_sk_m, pk_m} = Secp256k1.keypair(:xonly)
    nostr = Base.encode16(pk_m, case: :lower)

    assert {:ok, _} = Registrations.attach_member(group, "meshcore", mc)
    assert {:ok, _} = Registrations.attach_member(group, "nostr", nostr)

    Isthmus.Networks.Nostr.ServiceInbox.clear()

    {_sk2, stranger_pk} = Secp256k1.keypair(:xonly)
    stranger = Base.encode16(stranger_pk, case: :lower)
    ext = "svc-dm-#{System.unique_integer([:positive])}"

    Translator.ingest(%Message{
      from_network: :nostr,
      from_ref: stranger,
      to_ref: service_hex,
      body: "hello service key",
      external_id: ext,
      meta: %{"kind" => 1059, "subject" => Registrations.nostr_room_subject(group)}
    })

    _ = :sys.get_state(Translator)

    refute Enum.any?(
             Gateway.list_forward_log(30),
             &(&1.registration_group_id == group.id and &1.external_id == ext)
           )

    assert Enum.any?(Gateway.list_recent(30), fn row ->
             row.external_id == ext and row.status == "retained" and row.error == "service_inbox"
           end)

    [dm | _] = Isthmus.Networks.Nostr.ServiceInbox.list(5)
    assert dm.body == "hello service key"
    assert dm.from_ref == stranger
  end

  test "agent reply fans out to other attached legs" do
    owner = owner_hex()
    assert {:ok, group} = Registrations.create_bridge_group(owner, %{display_name: "Bot Camp"})
    mc = String.duplicate("44", 32)
    assert {:ok, _} = Registrations.attach_member(group, "meshcore", mc)
    assert {:ok, _} = Registrations.attach_member(group, "agent", "cursor")

    ext = "acp-test-#{System.unique_integer([:positive])}"

    Translator.ingest(%Message{
      from_network: :agent,
      from_ref: "cursor",
      body: "hello from the model",
      external_id: ext,
      meta: %{}
    })

    _ = :sys.get_state(Translator)

    assert Enum.any?(Gateway.list_forward_log(20), fn log ->
             log.registration_group_id == group.id and log.to_network == "meshcore" and
               log.external_id == ext
           end)
  end

  test "admin inject with group_id fans out to attached legs" do
    owner = owner_hex()
    assert {:ok, group} = Registrations.create_bridge_group(owner, %{display_name: "Inject Camp"})
    mc = String.duplicate("55", 32)
    assert {:ok, _} = Registrations.attach_member(group, "meshcore", mc)
    assert {:ok, _} = Registrations.attach_member(group, "agent", "cursor")

    ext = "ui-test-#{System.unique_integer([:positive])}"

    Translator.ingest(%Message{
      from_network: :admin,
      from_ref: "admin",
      body: "hello from the desk",
      group_id: group.id,
      external_id: ext,
      meta: %{"injected_by" => "admin"}
    })

    _ = :sys.get_state(Translator)

    logs =
      Enum.filter(
        Gateway.list_forward_log(20),
        &(&1.registration_group_id == group.id and &1.external_id == ext)
      )

    assert Enum.any?(logs, &(&1.to_network == "meshcore"))
    assert Enum.any?(logs, &(&1.to_network == "agent"))
  end

  defp owner_hex do
    {_seckey, pubkey} = Secp256k1.keypair(:xonly)
    Base.encode16(pubkey, case: :lower)
  end
end
