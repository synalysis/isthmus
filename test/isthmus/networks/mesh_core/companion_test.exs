defmodule Isthmus.Networks.MeshCore.CompanionTest do
  use Isthmus.DataCase, async: false

  alias Isthmus.Announce.Sightings
  alias Isthmus.Networks.MeshCore.Companion
  alias Isthmus.Networks.MeshCore.Companion.Frames

  test "clear_channel fails when disconnected" do
    assert {:error, :not_connected} = Companion.clear_channel(2)
  end

  test "contact frame records hops on the advert sighting" do
    Phoenix.PubSub.subscribe(Isthmus.PubSub, "announce:sightings")

    pubkey = :binary.copy(<<0xAB>>, 32)
    hex = Base.encode16(pubkey, case: :lower)
    path = <<0x01, 0x02>> <> :binary.copy(<<0>>, 62)
    name = String.pad_trailing("Trail", 32, <<0>>)

    frame =
      <<0x03, pubkey::binary, 1, 0, 2::signed-8, path::binary, name::binary, 0::little-32,
        0::signed-little-32, 0::signed-little-32, 0::little-32>>

    state = %{
      contacts: %{},
      self_info: nil,
      channels: %{},
      channel_sync_awaiting: nil,
      contacts_lastmod: 0,
      max_channels: 8
    }

    _ = Frames.apply(frame, state)
    assert_receive {:sighting, %{network: "meshcore"}}, 1_000

    assert %{hops: 2, meta: %{"name" => "Trail", "source" => "contact"}} =
             Sightings.best_for("meshcore", hex)
  end
end
