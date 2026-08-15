defmodule Isthmus.Networks.MeshCore.ChannelTest do
  use ExUnit.Case, async: true

  alias Isthmus.Networks.MeshCore.{Channel, Packet}

  test "public channel hash is 0x11 for the well-known PSK" do
    assert Channel.public_channel_hash() == 0x11
  end

  test "detects any group packet and Public by channel hash" do
    public =
      Packet.build(
        Packet.route_flood(),
        Channel.type_grp_txt(),
        0,
        <<>>,
        <<Channel.public_channel_hash(), 0, 0, "cipher">>
      )
      |> Packet.encode()

    private =
      Packet.build(
        Packet.route_flood(),
        Channel.type_grp_txt(),
        0,
        <<>>,
        <<0x42, 0, 0, "cipher">>
      )
      |> Packet.encode()

    advert =
      Packet.build(
        Packet.route_flood(),
        Packet.type_advert(),
        0,
        <<>>,
        :crypto.strong_rand_bytes(20)
      )
      |> Packet.encode()

    assert Channel.group_packet?(public)
    assert Channel.group_packet?(private)
    refute Channel.group_packet?(advert)

    assert Channel.public_group_packet?(public)
    refute Channel.public_group_packet?(private)
    refute Channel.public_group_packet?(advert)
  end

  test "public_slot? matches name or well-known PSK" do
    assert Channel.public_slot?(%{name: "Public", secret_hex: "00"})
    assert Channel.public_slot?(%{name: "Camp", secret_hex: Channel.public_psk_hex()})
    refute Channel.public_slot?(%{name: "Private", secret_hex: "aa"})
  end

  test "build/decrypt Public group text" do
    packet = Channel.build_group_text(Channel.public_psk(), "Ada", "ping")
    assert {:ok, %{name: "Ada", text: "ping"}} = Channel.decrypt_public_text(packet)
  end
end
