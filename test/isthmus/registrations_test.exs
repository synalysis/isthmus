defmodule Isthmus.RegistrationsTest do
  use Isthmus.DataCase, async: false

  alias Isthmus.Registrations
  alias Isthmus.Registrations.IdentityLeg
  alias Isthmus.Repo
  alias Isthmus.Vault

  test "register_self mints reticulum and meshcore legs" do
    {_seckey, pubkey} = Secp256k1.keypair(:xonly)
    hex = Base.encode16(pubkey, case: :lower)

    assert {:ok, group} = Registrations.register_self(hex, %{display_name: "Tester"})
    networks = group.legs |> Enum.map(& &1.network) |> Enum.sort() |> Enum.uniq()
    assert networks == ["meshcore", "nostr", "reticulum"]
    assert Enum.any?(group.legs, &(&1.network == "nostr" and &1.role == "primary"))
    proxy = Registrations.nostr_proxy_leg(group)
    assert proxy
    refute proxy.identity_ref == hex
    assert {:ok, _} = Registrations.nostr_proxy_seckey(group)
    assert group.kind == "registration"
  end

  test "register_meshcore_primary mints nostr and reticulum proxies" do
    owner = owner_hex()
    mc = String.duplicate("ab", 32)

    assert {:ok, group} =
             Registrations.register_meshcore_primary(owner, mc, %{
               display_name: "Radio One",
               created_by: "admin"
             })

    assert Enum.any?(group.legs, &(&1.network == "meshcore" and &1.role == "primary"))
    assert Enum.any?(group.legs, &(&1.network == "nostr" and &1.role == "proxy"))
    assert Enum.any?(group.legs, &(&1.network == "reticulum" and &1.role == "proxy"))

    targets = Registrations.other_legs(group, :meshcore)
    assert Enum.any?(targets, &(&1.network == "reticulum"))
    refute Enum.any?(targets, &(&1.network == "nostr"))
  end

  test "register_reticulum_primary mints proxies and prefers primary over receive proxy" do
    owner = owner_hex()
    dest = String.duplicate("cd", 16)

    assert {:ok, group} =
             Registrations.register_reticulum_primary(owner, dest, %{
               display_name: "RNS Home",
               created_by: "admin"
             })

    rns_legs = Enum.filter(group.legs, &(&1.network == "reticulum"))
    assert length(rns_legs) == 2
    assert Registrations.leg(group, :reticulum).role == "primary"
    assert Registrations.leg(group, :reticulum).identity_ref == dest
  end

  test "bridge group attach fanout and duplicate identity rejection" do
    owner = owner_hex()
    assert {:ok, group} = Registrations.create_bridge_group(owner, %{display_name: "Camp Bridge"})

    mc_a = String.duplicate("11", 32)
    mc_b = String.duplicate("22", 32)
    {_sk, pk} = Secp256k1.keypair(:xonly)
    nostr = Base.encode16(pk, case: :lower)

    assert {:ok, group} = Registrations.attach_member(group, "meshcore", mc_a)
    assert {:ok, group} = Registrations.attach_member(group, "meshcore", mc_b)
    assert {:ok, group} = Registrations.attach_member(group, "nostr", nostr)

    assert {:error, :identity_already_linked} =
             Registrations.attach_member(group, "meshcore", mc_a)

    others = Registrations.other_legs(group, :meshcore, mc_a)
    assert length(others) == 2
    assert Enum.any?(others, &(&1.identity_ref == mc_b))
    assert Enum.any?(others, &(&1.identity_ref == nostr))
    refute Enum.any?(others, &(&1.identity_ref == mc_a))
  end

  test "find_by_token matches display name slug and hex prefix" do
    owner = owner_hex()

    assert {:ok, group} =
             Registrations.create_bridge_group(owner, %{display_name: "Alice Camp"})

    mc = String.duplicate("ef", 32)
    assert {:ok, group} = Registrations.attach_member(group, "meshcore", mc)

    assert Registrations.find_by_token("@alice-camp").id == group.id
    assert Registrations.find_by_token("alice-camp").id == group.id
    assert Registrations.find_by_token(String.slice(mc, 0, 8)).id == group.id
    assert Registrations.find_by_token("@missing") == nil
  end

  test "nostr_room_subject and find_by_nostr_subject route by NIP-17 subject" do
    owner = owner_hex()

    assert {:ok, group} =
             Registrations.create_bridge_group(owner, %{display_name: "Lobby"})

    assert Registrations.nostr_room_subject(group) == "isthmus/lobby"
    assert Registrations.find_by_nostr_subject("isthmus/lobby").id == group.id
    assert Registrations.find_by_nostr_subject("lobby").id == group.id
    assert Registrations.find_by_nostr_subject("missing-room") == nil
  end

  test "revoke frees identity refs so they can be reattached" do
    owner = owner_hex()
    dest = String.duplicate("aa", 16)

    assert {:ok, old} = Registrations.create_bridge_group(owner, %{display_name: "Old Lobby"})
    assert {:ok, old} = Registrations.attach_member(old, "reticulum", dest)
    assert {:ok, _} = Registrations.revoke(old)

    assert Registrations.get_group!(old.id).legs == []

    assert {:ok, fresh} = Registrations.create_bridge_group(owner, %{display_name: "New Lobby"})
    assert {:ok, fresh} = Registrations.attach_member(fresh, "reticulum", dest)
    assert Enum.any?(fresh.legs, &(&1.identity_ref == dest and &1.network == "reticulum"))
  end

  test "attach reclaims orphaned legs left on revoked groups" do
    owner = owner_hex()
    dest = String.duplicate("bb", 16)

    assert {:ok, old} = Registrations.create_bridge_group(owner, %{display_name: "Orphan Bridge"})
    assert {:ok, old} = Registrations.attach_member(old, "reticulum", dest)

    # Simulate pre-fix revoke that left legs behind.
    {:ok, _} =
      old
      |> Ecto.Changeset.change(%{status: "revoked"})
      |> Repo.update()

    assert {:ok, fresh} = Registrations.create_bridge_group(owner, %{display_name: "Reuse"})
    assert {:ok, fresh} = Registrations.attach_member(fresh, "reticulum", dest)
    assert length(Enum.filter(fresh.legs, &(&1.network == "reticulum"))) == 1
  end

  test "link_meshcore_channel stores encrypted secret and enforces uniqueness" do
    owner = owner_hex()
    assert {:ok, g1} = Registrations.create_bridge_group(owner, %{display_name: "Ch A"})
    assert {:ok, g2} = Registrations.create_bridge_group(owner, %{display_name: "Ch B"})
    secret = String.duplicate("ab", 16)

    assert {:ok, linked} = Registrations.link_meshcore_channel(g1, 2, secret)
    assert linked.meshcore_channel_idx == 2
    assert linked.meshcore_channel_secret_enc != nil

    assert Registrations.find_by_meshcore_channel(2).id == g1.id
    assert {:error, :channel_already_linked} = Registrations.link_meshcore_channel(g2, 2, secret)

    assert {:ok, _} = Registrations.unlink_meshcore_channel(linked)
    assert Registrations.find_by_meshcore_channel(2) == nil
  end

  test "meshcore_channel_invite returns secret and meshcore URI" do
    owner = owner_hex()
    assert {:ok, group} = Registrations.create_bridge_group(owner, %{display_name: "Camp Radio"})
    secret = String.duplicate("cd", 16)

    assert {:error, :no_channel_linked} = Registrations.meshcore_channel_invite(group)

    assert {:ok, linked} = Registrations.link_meshcore_channel(group, 3, secret)
    assert {:ok, invite} = Registrations.meshcore_channel_invite(linked)

    assert invite.slot == 3
    assert invite.name == "Camp Radio"
    assert invite.secret_hex == secret
    assert invite.uri == "meshcore://channel/add?name=Camp+Radio&secret=#{secret}"

    assert {:ok, unlinked} = Registrations.unlink_meshcore_channel(linked)
    assert {:error, :no_channel_linked} = Registrations.meshcore_channel_invite(unlinked)

    assert {:ok, _} = Registrations.link_meshcore_channel(unlinked, 3, secret)
    assert {:ok, revoked} = Registrations.revoke(Registrations.get_group!(unlinked.id))
    assert {:error, :no_channel_linked} = Registrations.meshcore_channel_invite(revoked)
  end

  test "link_meshtastic_channel stores encrypted PSK and enforces uniqueness" do
    owner = owner_hex()
    assert {:ok, g1} = Registrations.create_bridge_group(owner, %{display_name: "MT A"})
    assert {:ok, g2} = Registrations.create_bridge_group(owner, %{display_name: "MT B"})
    psk = String.duplicate("ab", 16)

    assert {:ok, linked} = Registrations.link_meshtastic_channel(g1, 2, psk)
    assert linked.meshtastic_channel_idx == 2
    assert linked.meshtastic_channel_psk_enc != nil

    assert Registrations.find_by_meshtastic_channel(2).id == g1.id
    assert {:error, :channel_already_linked} = Registrations.link_meshtastic_channel(g2, 2, psk)

    assert {:ok, _} = Registrations.unlink_meshtastic_channel(linked)
    assert Registrations.find_by_meshtastic_channel(2) == nil
  end

  test "meshtastic_channel_invite returns PSK and meshtastic URL" do
    owner = owner_hex()
    assert {:ok, group} = Registrations.create_bridge_group(owner, %{display_name: "Camp Radio"})
    psk = String.duplicate("cd", 16)

    assert {:error, :no_channel_linked} = Registrations.meshtastic_channel_invite(group)

    assert {:ok, linked} = Registrations.link_meshtastic_channel(group, 3, psk)
    assert {:ok, invite} = Registrations.meshtastic_channel_invite(linked)

    assert invite.slot == 3
    assert invite.name == "Camp Radio"
    assert invite.psk_hex == psk
    assert String.starts_with?(invite.uri, "https://meshtastic.org/e/#")
    assert String.contains?(invite.uri, "?add=true")

    assert {:ok, unlinked} = Registrations.unlink_meshtastic_channel(linked)
    assert {:error, :no_channel_linked} = Registrations.meshtastic_channel_invite(unlinked)
  end

  test "create_bridge_with_meshtastic_channel requires a live companion" do
    owner = owner_hex()

    assert {:error, :not_connected} =
             Registrations.create_bridge_with_meshtastic_channel(owner, %{display_name: "NoRadio"})
  end

  test "provision_meshtastic_channel requires a live companion" do
    owner = owner_hex()
    assert {:ok, group} = Registrations.create_bridge_group(owner, %{display_name: "Lobby"})

    assert {:error, :not_connected} = Registrations.provision_meshtastic_channel(group)
  end

  test "provision_meshcore_channel requires a live companion" do
    owner = owner_hex()
    assert {:ok, group} = Registrations.create_bridge_group(owner, %{display_name: "Lobby"})

    assert {:error, :not_connected} = Registrations.provision_meshcore_channel(group)
  end

  test "ensure_reticulum_ready remints stub seed_hex legs when sidecar is live" do
    {_seckey, pubkey} = Secp256k1.keypair(:xonly)
    hex = Base.encode16(pubkey, case: :lower)
    assert {:ok, group} = Registrations.register_self(hex, %{display_name: "StubUpgrade"})
    leg = Registrations.leg(group, :reticulum)

    {:ok, enc} =
      Vault.encrypt(%{"seed_hex" => Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)})

    {:ok, stub} =
      leg
      |> IdentityLeg.changeset(%{
        identity_ref: "aabbccddeeff00112233445566778899",
        public_material: %{
          "destination_hash" => "aabbccddeeff00112233445566778899",
          "app" => "lxmf.delivery",
          "note" => "stub_until_rns_sidecar_mints_real_identity"
        },
        encrypted_private_material: enc
      })
      |> Repo.update()

    case Registrations.ensure_reticulum_ready(stub) do
      {:ok, ready} ->
        refute ready.identity_ref == stub.identity_ref
        refute get_in(ready.public_material, ["note"])
        assert {:ok, _} = Vault.decrypt(ready.encrypted_private_material)

      {:error, :rns_not_live} ->
        :ok

      {:error, :rns_still_stub} ->
        :ok

      {:error, :stub_mode} ->
        :ok

      {:error, other} ->
        flunk("unexpected: #{inspect(other)}")
    end
  end

  test "announce_leg rejects attached reticulum members; ensure_bridge_rns_proxy mints proxy" do
    assert {:ok, group} =
             Registrations.create_bridge_group(owner_hex(), %{display_name: "PathBridge"})

    assert {:ok, group} =
             Registrations.attach_member(
               group,
               "reticulum",
               "6d105c6ddcf9f9225ecd9f428520ca72"
             )

    member = Enum.find(group.legs, &(&1.network == "reticulum" and &1.role == "member"))
    refute Registrations.can_announce_leg?(member)
    assert Registrations.external_reticulum_leg?(member)
    assert {:error, :external_identity} = Registrations.announce_leg(member)

    assert {:ok, with_proxy} = Registrations.ensure_bridge_rns_proxy(group)
    proxy = Enum.find(with_proxy.legs, &(&1.network == "reticulum" and &1.role == "proxy"))
    assert proxy
    assert Registrations.can_announce_leg?(proxy)
  end

  test "ensure_nostr_proxy mints vaulted proxy and exposes seckey" do
    assert {:ok, group} =
             Registrations.create_bridge_group(owner_hex(), %{display_name: "NostrBridge"})

    refute Registrations.nostr_proxy_leg(group)

    assert {:ok, with_proxy} = Registrations.ensure_nostr_proxy(group)
    proxy = Registrations.nostr_proxy_leg(with_proxy)
    assert proxy
    assert proxy.role == "proxy"
    assert {:ok, seckey} = Registrations.nostr_proxy_seckey(with_proxy)
    assert byte_size(seckey) == 32

    # Idempotent
    assert {:ok, again} = Registrations.ensure_nostr_proxy(with_proxy)
    assert Registrations.nostr_proxy_leg(again).id == proxy.id

    inboxes = Registrations.list_nostr_inbox_keypairs()
    assert Enum.any?(inboxes, fn {pk, _} -> pk == proxy.identity_ref end)
  end

  defp owner_hex do
    {_seckey, pubkey} = Secp256k1.keypair(:xonly)
    Base.encode16(pubkey, case: :lower)
  end
end
