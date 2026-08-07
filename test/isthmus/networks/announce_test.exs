defmodule Isthmus.Networks.AnnounceTest do
  use Isthmus.DataCase, async: false

  alias Isthmus.Networks
  alias Isthmus.Networks.MeshCore.Protocol
  alias Isthmus.Registrations

  test "supports_announce? is true for reticulum and meshcore" do
    assert Networks.supports_announce?(:reticulum)
    assert Networks.supports_announce?(:meshcore)
    refute Networks.supports_announce?(:nostr)
    refute Networks.supports_announce?(:meshtastic)
  end

  test "meshcore self-advert frame encodes flood flag" do
    assert Protocol.send_self_advert_frame(false) == <<7, 0>>
    assert Protocol.send_self_advert_frame(true) == <<7, 1>>
  end

  test "parses PUSH_CODE_ADVERT with 32-byte pubkey" do
    pk = :crypto.strong_rand_bytes(32)
    assert {:advert, hex} = Protocol.parse_frame(<<0x80, pk::binary>>)
    assert hex == Base.encode16(pk, case: :lower)
  end

  test "announce_group returns results for announceable legs" do
    {_sk, pk} = Secp256k1.keypair(:xonly)
    hex = Base.encode16(pk, case: :lower)
    assert {:ok, group} = Registrations.register_self(hex, %{display_name: "Ann"})

    assert {:ok, results} = Registrations.announce_group(group, %{force: true})
    assert Enum.any?(results, fn {net, _} -> net == "reticulum" end)
    assert Enum.any?(results, fn {net, _} -> net == "meshcore" end)
  end
end
