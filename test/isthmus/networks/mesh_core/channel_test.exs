defmodule Isthmus.Networks.MeshCore.ChannelTest do
  use ExUnit.Case, async: true

  alias Isthmus.Networks.MeshCore.{Channel, Packet}

  test "public channel hash is 0x11 for the well-known PSK" do
    assert Channel.public_channel_hash() == 0x11
  end

  test "detects GRP_TXT / GRP_DATA for Public by channel hash byte" do
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

    assert Channel.public_group_packet?(public)
    refute Channel.public_group_packet?(private)
    refute Channel.public_group_packet?(advert)
  end
end
