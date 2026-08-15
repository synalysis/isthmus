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

  test "channel_msg during slot sync is held until flush" do
    frame = <<0x08, 0, 0, 0, 1_700_000_050::little-32, "Camp: offline hello">>

    state = %{
      contacts: %{},
      self_info: %{public_key: "aa"},
      channels: %{},
      channel_sync_awaiting: 0,
      channel_sync_queue: [1],
      contacts_lastmod: 0,
      max_channels: 8,
      pending_channel_msgs: []
    }

    state = Frames.apply(frame, state)
    assert length(state.pending_channel_msgs) == 1
    refute Enum.any?(Isthmus.Messages.list_recent(20), &(&1.body == "offline hello"))

    slot = %{
      index: 0,
      name: "Public",
      secret_hex: Isthmus.Networks.MeshCore.Channel.public_psk_hex()
    }

    pending = Enum.map(state.pending_channel_msgs, &Map.put(&1, :slot, slot))
    _ = Frames.flush_pending(%{state | pending_channel_msgs: pending})
    _ = :sys.get_state(Isthmus.Gateway.Translator)
    _ = :sys.get_state(Isthmus.Gateway.Translator)

    assert Enum.any?(Isthmus.Messages.list_recent(20), fn row ->
             row.network == "meshcore" and row.body == "offline hello" and
               row.sender_name == "Camp"
           end)
  end

  test "channel_msg records immediately once Public slots are known" do
    frame = <<0x08, 0, 0, 0, 1_700_000_060::little-32, "Ridge: live now">>

    state = %{
      contacts: %{},
      self_info: %{public_key: "aa"},
      channels: %{
        0 => %{
          index: 0,
          name: "Public",
          secret_hex: Isthmus.Networks.MeshCore.Channel.public_psk_hex()
        }
      },
      channel_sync_awaiting: nil,
      channel_sync_queue: [],
      contacts_lastmod: 0,
      max_channels: 8,
      pending_channel_msgs: []
    }

    _ = Frames.apply(frame, state)
    _ = :sys.get_state(Isthmus.Gateway.Translator)
    _ = :sys.get_state(Isthmus.Gateway.Translator)

    assert Enum.any?(Isthmus.Messages.list_recent(20), fn row ->
             row.body == "live now" and row.sender_name == "Ridge"
           end)
  end

  test "ble_frame notify is applied like a USB companion frame" do
    Phoenix.PubSub.subscribe(Isthmus.PubSub, "announce:sightings")

    pubkey = :binary.copy(<<0xCD>>, 32)
    hex = Base.encode16(pubkey, case: :lower)
    path = <<0x01, 0x02>> <> :binary.copy(<<0>>, 62)
    name = String.pad_trailing("RidgeBLE", 32, <<0>>)

    frame =
      <<0x03, pubkey::binary, 1, 0, 2::signed-8, path::binary, name::binary, 0::little-32,
        0::signed-little-32, 0::signed-little-32, 0::little-32>>

    pid = Process.whereis(Companion)
    send(pid, {:ble_frame, frame})
    _ = :sys.get_state(pid)

    assert_receive {:sighting, %{network: "meshcore"}}, 1_000

    assert %{hops: 2, meta: %{"name" => "RidgeBLE", "source" => "contact"}} =
             Sightings.best_for("meshcore", hex)
  end
end
