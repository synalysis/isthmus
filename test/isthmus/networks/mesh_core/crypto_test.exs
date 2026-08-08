defmodule Isthmus.Networks.MeshCore.CryptoTest do
  use ExUnit.Case, async: true

  alias Isthmus.Networks.MeshCore.Advert
  alias Isthmus.Networks.MeshCore.Crypto
  alias Isthmus.Networks.MeshCore.Packet
  alias Isthmus.Networks.MeshCore.Path
  alias Isthmus.Networks.MeshCore.TxtMsg

  # Golden vectors from MeshCore Nightcracker ECDH / encryptThenMAC harness.
  @seed_a Base.decode16!("0102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F20",
            case: :mixed
          )
  @seed_b Base.decode16!("6465666768696A6B6C6D6E6F707172737475767778797A7B7C7D7E7F80818283",
            case: :mixed
          )
  @ss_ab Base.decode16!("E5F548898286954A7179A75C17C61E3386D756AE0AAB490707D1A047CE548C7A",
           case: :mixed
         )
  @hello_wire Base.decode16!("9DEA1046AC4C0116176FF4B696875BB448C5", case: :mixed)

  describe "ECDH" do
    test "matches firmware shared secret for fixed seeds" do
      {pub_a, _} = Crypto.keypair_from_seed(@seed_a)
      {pub_b, _} = Crypto.keypair_from_seed(@seed_b)

      assert Crypto.shared_secret(@seed_a, pub_b) == @ss_ab
      assert Crypto.shared_secret(@seed_b, pub_a) == @ss_ab
    end

    test "is commutative for random keypairs (sign-bit cleared)" do
      for _ <- 1..16 do
        {pub_a, seed_a} = Crypto.generate_keypair()
        {pub_b, seed_b} = Crypto.generate_keypair()
        assert Crypto.shared_secret(seed_a, pub_b) == Crypto.shared_secret(seed_b, pub_a)
      end
    end
  end

  describe "encryptThenMAC" do
    test "golden wire for hello mesh" do
      assert Crypto.encrypt_then_mac(@ss_ab, "hello mesh") == @hello_wire
      assert {:ok, pt} = Crypto.mac_then_decrypt(@ss_ab, @hello_wire)
      assert binary_part(pt, 0, byte_size("hello mesh")) == "hello mesh"
    end
  end

  describe "packet round-trip" do
    test "flood advert header + path packing" do
      payload = :crypto.strong_rand_bytes(40)

      encoded =
        Packet.build(Packet.route_flood(), Packet.type_advert(), 0, <<>>, payload)
        |> Packet.encode()

      assert {:ok, decoded} = Packet.decode(encoded)
      assert decoded.route == Packet.route_flood()
      assert decoded.payload_type == Packet.type_advert()
      assert decoded.payload == payload
    end
  end

  describe "advert" do
    test "signs and verifies" do
      {pub, seed} = Crypto.keypair_from_seed(@seed_a)
      blob = Advert.build_flood(seed, pub, "Isthmus", 1_700_000_000)
      assert {:ok, pkt} = Packet.decode(blob)
      assert pkt.payload_type == Packet.type_advert()
      assert {:ok, parsed} = Advert.parse_payload(pkt.payload)
      assert parsed.public_key == pub
      assert parsed.name == "Isthmus"
    end
  end

  describe "TXT_MSG + PATH" do
    test "encrypt/decrypt DM and PATH return with bundled ACK" do
      {pub_a, seed_a} = Crypto.keypair_from_seed(@seed_a)
      {pub_b, seed_b} = Crypto.keypair_from_seed(@seed_b)

      assert {:ok, %{packet: dm}} =
               TxtMsg.build(
                 seed: seed_a,
                 our_pub: pub_a,
                 dest_pub: pub_b,
                 text: "ping",
                 timestamp: 1_700_000_001,
                 attempt: 0
               )

      assert {:ok, %{text: "ping", from_pub: ^pub_a, ack: ack}} =
               TxtMsg.decrypt(seed_b, pub_b, dm, [pub_a])

      assert byte_size(ack) == 6

      # B returns PATH with reverse path + ACK (flood path = one hop repeater hash)
      path_len = Packet.encode_path_len(1)
      path = <<0xAB>>

      path_blob =
        Path.build_return(
          seed: seed_b,
          our_pub: pub_b,
          dest_pub: pub_a,
          path: path,
          path_len: path_len,
          extra: ack
        )

      assert {:ok, learned} = Path.decrypt(seed_a, pub_a, path_blob, pub_b)
      assert learned.out_path == path
      assert learned.out_path_len == path_len
      assert learned.extra_type == Packet.type_ack()
      assert binary_part(learned.extra, 0, 4) == binary_part(ack, 0, 4)
    end

    test "direct send when out_path known" do
      {pub_a, seed_a} = Crypto.keypair_from_seed(@seed_a)
      {pub_b, seed_b} = Crypto.keypair_from_seed(@seed_b)
      path = <<0xCD>>
      path_len = Packet.encode_path_len(1)

      assert {:ok, %{packet: dm}} =
               TxtMsg.build(
                 seed: seed_a,
                 our_pub: pub_a,
                 dest_pub: pub_b,
                 text: "direct",
                 route: Packet.route_direct(),
                 path_len: path_len,
                 path: path
               )

      assert {:ok, pkt} = Packet.decode(dm)
      assert Packet.direct?(pkt)
      assert pkt.path_len == path_len
      assert {:ok, %{text: "direct"}} = TxtMsg.decrypt(seed_b, pub_b, dm, [pub_a])
    end
  end

  describe "generate_keypair" do
    test "never returns reserved node hash prefixes" do
      for _ <- 1..8 do
        {pub, seed} = Crypto.generate_keypair()
        assert byte_size(pub) == 32
        assert byte_size(seed) == 32
        refute :binary.at(pub, 0) in [0x00, 0xFF]
      end
    end
  end
end
