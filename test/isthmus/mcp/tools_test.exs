defmodule Isthmus.MCP.ToolsTest do
  use Isthmus.DataCase, async: false

  alias Isthmus.Accounts
  alias Isthmus.Gateway
  alias Isthmus.Gateway.Translator
  alias Isthmus.MCP.Tools
  alias Isthmus.Nostr.Bech32
  alias Isthmus.Registrations

  test "create_group attach_member inject_message and get by name" do
    owner = owner_hex()
    {:ok, _} = Accounts.add_admin(%{pubkey_hex: owner, npub: npub_for(owner), label: "ops"})

    assert {:ok, created} = Tools.create_group(%{"name" => "MCP Lobby"})
    assert created.name == "MCP Lobby"
    assert created.kind == "bridge"
    assert created.status == "active"

    mc = String.duplicate("ab", 32)

    assert {:ok, attached} =
             Tools.attach_member(%{
               "group" => "MCP Lobby",
               "network" => "meshcore",
               "identity" => mc
             })

    assert Enum.any?(attached.members, &(&1.network == "meshcore" and &1.identity == mc))

    assert {:ok, fetched} = Tools.get_group(%{group: "mcp lobby"})
    assert fetched.id == created.id

    assert {:ok, %{ok: true, body: "hello mesh"}} =
             Tools.inject_message(%{group: created.id, body: "hello mesh"})

    _ = :sys.get_state(Translator)

    assert Enum.any?(Gateway.list_forward_log(20), fn log ->
             log.registration_group_id == created.id and log.to_network == "meshcore"
           end)

    assert {:ok, %{groups: groups}} = Tools.list_groups(%{})
    assert Enum.any?(groups, &(&1.id == created.id))
  end

  test "create_group defaults owner to the first admin" do
    owner = owner_hex()
    {:ok, _} = Accounts.add_admin(%{pubkey_hex: owner, npub: npub_for(owner), label: "ops"})

    assert {:ok, group} = Tools.create_group(%{name: "Owned"})
    assert group.owner == owner
  end

  test "create_group errors without an admin or owner" do
    assert {:error, reason} = Tools.create_group(%{name: "No Owner"})
    assert reason =~ "no admin"
  end

  test "unknown group is an error" do
    assert {:error, "group not found: missing"} = Tools.get_group(%{group: "missing"})
  end

  test "get_policy and set_policy round-trip" do
    assert {:ok, %{settings: settings}} = Tools.get_policy(%{})
    assert is_boolean(settings["registration_open"])

    assert {:ok, %{key: "registration_open", value: false}} =
             Tools.set_policy(%{key: "registration_open", value: false})

    assert {:ok, %{settings: updated}} = Tools.get_policy(%{})
    assert updated["registration_open"] == false
  end

  test "detach_member removes an attached identity" do
    owner = owner_hex()
    {:ok, group} = Registrations.create_bridge_group(owner, %{display_name: "Detach Me"})
    mc = String.duplicate("cd", 32)
    assert {:ok, _} = Registrations.attach_member(group, "meshcore", mc)

    assert {:ok, dumped} =
             Tools.detach_member(%{group: "Detach Me", identity: mc, network: "meshcore"})

    refute Enum.any?(dumped.members, &(&1.identity == mc))
  end

  defp owner_hex do
    {_seckey, pubkey} = Secp256k1.keypair(:xonly)
    Base.encode16(pubkey, case: :lower)
  end

  defp npub_for(hex) do
    {:ok, raw} = Base.decode16(hex, case: :mixed)
    Bech32.encode_npub(raw)
  end
end
