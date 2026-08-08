defmodule Isthmus.Networks.MeshCore.SyntheticNodeTest do
  use Isthmus.DataCase, async: false

  alias Isthmus.Networks.MeshCore
  alias Isthmus.Networks.MeshCore.Advert
  alias Isthmus.Networks.MeshCore.Crypto
  alias Isthmus.Networks.MeshCore.Packet
  alias Isthmus.Networks.MeshCore.Path
  alias Isthmus.Networks.MeshCore.SyntheticNode
  alias Isthmus.Networks.MeshCore.TxtMsg
  alias Isthmus.Registrations
  alias Isthmus.Registrations.IdentityLeg
  alias Isthmus.Repo
  alias Isthmus.Vault

  setup do
    {pub, seed} = Crypto.generate_keypair()
    hex = Base.encode16(pub, case: :lower)
    name = "Synth#{System.unique_integer([:positive])}"
    owner = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

    {:ok, group} =
      Registrations.create_bridge_group(owner, %{display_name: name, created_by: "admin"})

    {:ok, mc} = MeshCore.generate_proxy_identity(%{name: name})

    {:ok, enc} =
      Vault.encrypt(%{
        "secret_hex" => Base.encode16(seed, case: :lower),
        "public_key" => hex
      })

    {:ok, _} =
      %IdentityLeg{}
      |> IdentityLeg.changeset(%{
        registration_group_id: group.id,
        network: "meshcore",
        role: "proxy",
        identity_ref: hex,
        public_material: %{"public_key" => hex, "name" => name, "type" => 1},
        presentation_cache: %{items: mc.presentations},
        encrypted_private_material: enc
      })
      |> Repo.insert()

    test_pid = self()
    name_atom = :"synthetic_#{System.unique_integer([:positive])}"

    inject = fn packet ->
      send(test_pid, {:injected, packet})
      :ok
    end

    pid =
      start_supervised!(
        {SyntheticNode,
         name: name_atom, inject: inject, bridge_health: fn -> %{status: :online} end}
      )

    Ecto.Adapters.SQL.Sandbox.allow(Repo, test_pid, pid)
    SyntheticNode.reload(name_atom)
    _ = :sys.get_state(pid)

    {:ok, name: name_atom, pid: pid, seed: seed, pub: pub, hex: hex}
  end

  test "loads proxy identity and announces", %{name: name, hex: hex} do
    assert SyntheticNode.has_identity?(name, hex)
    assert :ok = SyntheticNode.announce(name, hex, %{force: true})
    assert_receive {:injected, packet}, 1_000
    assert {:ok, pkt} = Packet.decode(packet)
    assert pkt.payload_type == Packet.type_advert()
  end

  test "decrypts flood DM, returns PATH+ACK, learns path for direct send", %{
    name: name,
    hex: hex,
    pub: pub,
    pid: pid
  } do
    {peer_pub, peer_seed} = Crypto.generate_keypair()

    advert = Advert.build_flood(peer_seed, peer_pub, "Peer", 1_700_000_000)
    send(pid, {:bridge_packet, advert})
    _ = :sys.get_state(pid)

    path_len = Packet.encode_path_len(1)
    path = <<0x42>>

    assert {:ok, %{packet: dm}} =
             TxtMsg.build(
               seed: peer_seed,
               our_pub: peer_pub,
               dest_pub: pub,
               text: "hello synth",
               timestamp: 1_700_000_100,
               route: Packet.route_flood(),
               path_len: path_len,
               path: path
             )

    Phoenix.PubSub.subscribe(Isthmus.PubSub, "meshcore:inbound")
    send(pid, {:bridge_packet, dm})
    _ = :sys.get_state(pid)

    assert_receive {:meshcore_dm, %{body: "hello synth", to_ref: ^hex}}, 1_000
    assert_receive {:injected, path_packet}, 1_000
    assert {:ok, path_pkt} = Packet.decode(path_packet)
    assert path_pkt.payload_type == Packet.type_path()

    peer_hex = Base.encode16(peer_pub, case: :lower)

    path_return =
      Path.build_return(
        seed: peer_seed,
        our_pub: peer_pub,
        dest_pub: pub,
        path: <<0x99>>,
        path_len: Packet.encode_path_len(1),
        extra: <<1, 2, 3, 4, 0, 0>>
      )

    send(pid, {:bridge_packet, path_return})
    _ = :sys.get_state(pid)

    assert :ok = SyntheticNode.send_text(name, hex, peer_hex, "reply")
    assert_receive {:injected, out}, 1_000
    assert {:ok, out_pkt} = Packet.decode(out)
    assert Packet.direct?(out_pkt)
    assert {:ok, %{text: "reply"}} = TxtMsg.decrypt(peer_seed, peer_pub, out, [pub])
  end

  test "duplicate inbound DM arriving via multiple tunnels is delivered once", %{
    name: _name,
    hex: hex,
    pub: pub,
    pid: pid
  } do
    {peer_pub, peer_seed} = Crypto.generate_keypair()

    advert = Advert.build_flood(peer_seed, peer_pub, "Peer", 1_700_000_000)
    send(pid, {:bridge_packet, advert})
    _ = :sys.get_state(pid)

    assert {:ok, %{packet: dm}} =
             TxtMsg.build(
               seed: peer_seed,
               our_pub: peer_pub,
               dest_pub: pub,
               text: "dupe",
               timestamp: 1_700_000_222,
               route: Packet.route_flood(),
               path_len: Packet.encode_path_len(1),
               path: <<0x01>>
             )

    # Same DM as it arrives via a second tunnel: identical payload, longer path.
    {:ok, dm_map} = Packet.decode(dm)

    dm2 =
      %{dm_map | path_len: Packet.encode_path_len(2), path: <<0x01, 0x02>>}
      |> Packet.encode()

    Phoenix.PubSub.subscribe(Isthmus.PubSub, "meshcore:inbound")

    send(pid, {:bridge_packet, dm})
    _ = :sys.get_state(pid)
    send(pid, {:bridge_packet, dm2})
    _ = :sys.get_state(pid)

    assert_receive {:meshcore_dm, %{body: "dupe", to_ref: ^hex}}, 1_000
    refute_receive {:meshcore_dm, %{body: "dupe"}}, 200

    # Exactly one PATH+ACK injected for the DM (deduped copy emits nothing).
    assert_receive {:injected, _}, 1_000
    refute_receive {:injected, _}, 200
  end

  test "stays disabled when bridge offline", %{hex: hex} do
    name = :"synthetic_off_#{System.unique_integer([:positive])}"
    test_pid = self()

    pid =
      start_supervised!(
        {SyntheticNode,
         name: name, inject: fn _ -> :ok end, bridge_health: fn -> %{status: :disabled} end}
      )

    Ecto.Adapters.SQL.Sandbox.allow(Repo, test_pid, pid)
    SyntheticNode.reload(name)
    _ = :sys.get_state(pid)

    assert {:error, :bridge_offline} = SyntheticNode.announce(name, hex, %{force: true})
  end
end
