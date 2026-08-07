defmodule Isthmus.Gateway.TranslatorTest do
  use Isthmus.DataCase, async: false

  alias Isthmus.Gateway
  alias Isthmus.Gateway.Message
  alias Isthmus.Gateway.Translator
  alias Isthmus.Registrations

  test "bridges meshcore message to other legs for a registration" do
    {_sk, pk} = Secp256k1.keypair(:xonly)
    hex = Base.encode16(pk, case: :lower)
    assert {:ok, group} = Registrations.register_self(hex, %{display_name: "GW"})

    mesh = Registrations.leg(group, :meshcore)

    Translator.ingest(%Message{
      from_network: :meshcore,
      from_ref: "aabbccdd" <> String.duplicate("00", 28),
      to_ref: mesh.identity_ref,
      body: "hello from mesh",
      external_id: "mesh-1"
    })

    Process.sleep(50)
    recent = Gateway.list_recent(10)

    assert Enum.any?(recent, fn row ->
             row.from_network == "meshcore" and row.status in ["delivered", "failed"] and
               (row.meta["body_bytes"] || 0) > 0
           end)
  end

  test "dedupes repeated external_id" do
    {_sk, pk} = Secp256k1.keypair(:xonly)
    hex = Base.encode16(pk, case: :lower)
    assert {:ok, group} = Registrations.register_self(hex, %{display_name: "Dedup"})
    mesh = Registrations.leg(group, :meshcore)

    msg = %Message{
      from_network: :meshcore,
      from_ref: "bbccddee" <> String.duplicate("11", 28),
      to_ref: mesh.identity_ref,
      body: "once only",
      external_id: "dup-id-1"
    }

    Translator.ingest(msg)
    Translator.ingest(msg)
    Process.sleep(50)

    hits =
      Gateway.list_recent(20)
      |> Enum.filter(&(&1.external_id == "dup-id-1"))

    # One ingest yields one log row per destination leg (nostr + reticulum) = 2, not 4
    assert length(hits) == 2
    refute Enum.any?(hits, &(&1.body not in [nil, ""]))
  end

  test "drops when direction is denied by policy" do
    {_sk, pk} = Secp256k1.keypair(:xonly)
    hex = Base.encode16(pk, case: :lower)
    assert {:ok, group} = Registrations.register_self(hex, %{display_name: "Policy"})
    mesh = Registrations.leg(group, :meshcore)

    {:ok, _} =
      Isthmus.Policy.put("gateway_deny_directions", ["meshcore>nostr", "meshcore>reticulum"])

    Translator.ingest(%Message{
      from_network: :meshcore,
      from_ref: "ccddeeff" <> String.duplicate("22", 28),
      to_ref: mesh.identity_ref,
      body: "blocked",
      external_id: "policy-drop-1"
    })

    Process.sleep(50)

    hits =
      Gateway.list_recent(20)
      |> Enum.filter(&(&1.external_id == "policy-drop-1"))

    assert length(hits) == 2
    assert Enum.all?(hits, &(&1.status == "dropped"))
    assert Enum.all?(hits, &String.contains?(&1.error || "", "direction_denied"))
  end

  test "remembers mesh peer for later nostr→meshcore routing" do
    {_sk, pk} = Secp256k1.keypair(:xonly)
    hex = Base.encode16(pk, case: :lower)
    assert {:ok, group} = Registrations.register_self(hex, %{display_name: "Peer"})
    mesh = Registrations.leg(group, :meshcore)
    peer = "ccddeeff" <> String.duplicate("22", 28)

    Translator.ingest(%Message{
      from_network: :meshcore,
      from_ref: peer,
      to_ref: mesh.identity_ref,
      body: "ping",
      external_id: "peer-1"
    })

    Process.sleep(50)
    assert Gateway.last_mesh_peer(group.id) == peer
  end
end
