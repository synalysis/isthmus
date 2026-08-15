defmodule Isthmus.MessagesTest do
  use Isthmus.DataCase, async: false

  alias Isthmus.Messages
  alias Isthmus.Networks.MeshCore.Channel
  alias Isthmus.Registrations

  test "records and lists Public channel messages" do
    assert {:ok, _} =
             Messages.record(%{
               kind: "channel",
               network: "meshcore",
               channel_name: "Public",
               sender_name: "Mobby",
               body: "hello camp"
             })

    assert {:ok, _} =
             Messages.record(%{
               kind: "channel",
               network: "meshtastic",
               channel_name: "Primary",
               from_ref: "aabbccdd",
               body: "trail check"
             })

    rows = Messages.list_recent(20)
    assert Enum.any?(rows, &(&1.body == "hello camp" and &1.network == "meshcore"))
    assert Enum.any?(rows, &(&1.body == "trail check" and &1.network == "meshtastic"))

    only_mc = Messages.list_recent(20, networks: ["meshcore"])
    assert Enum.all?(only_mc, &(&1.network == "meshcore"))
  end

  test "decrypts Public GRP_TXT built with the well-known PSK" do
    packet = Channel.build_group_text(Channel.public_psk(), "Camp", "weather is fine")
    assert Channel.public_group_packet?(packet)
    assert {:ok, parsed} = Channel.decrypt_public_text(packet)
    assert parsed.name == "Camp"
    assert parsed.text == "weather is fine"

    assert {:ok, %Messages.Heard{} = row} = Messages.maybe_record_meshcore_packet(packet)
    assert row.kind == "channel"
    assert row.channel_name == "Public"
    assert row.body == "weather is fine"
    assert row.sender_name == "Camp"
  end

  test "group messages are skipped unless that group stores them" do
    {_seckey, pubkey} = Secp256k1.keypair(:xonly)
    hex = Base.encode16(pubkey, case: :lower)
    assert {:ok, group} = Registrations.register_self(hex, %{display_name: "Lobby"})

    msg = %Isthmus.Gateway.Message{
      from_network: :nostr,
      from_ref: hex,
      body: "secret group chat",
      meta: %{}
    }

    assert {:ok, :skipped} = Messages.maybe_record_group(msg, group)
    refute Enum.any?(Messages.list_recent(20), &(&1.body == "secret group chat"))

    assert {:ok, group} = Registrations.set_store_messages(group, true)
    assert {:ok, %Messages.Heard{} = row} = Messages.maybe_record_group(msg, group)
    assert row.kind == "group"
    assert row.channel_name == "Lobby"
    assert row.body == "secret group chat"
  end

  test "duplicate external_id is not stored twice" do
    attrs = %{
      kind: "channel",
      network: "meshtastic",
      channel_name: "Primary",
      body: "same packet",
      external_id: "mt-4242"
    }

    assert {:ok, %Messages.Heard{}} = Messages.record(attrs)
    assert {:ok, :duplicate} = Messages.record(attrs)
    assert Enum.count(Messages.list_recent(50), &(&1.external_id == "mt-4242")) == 1
  end

  test "companion channel backfill uses the radio timestamp" do
    seen = DateTime.from_unix!(1_700_000_000)

    assert {:ok, row} =
             Messages.maybe_record_meshcore_channel(%{
               channel_idx: 0,
               body: "Camp: queued while down",
               seen_at: seen,
               meta: %{timestamp: 1_700_000_000}
             })

    assert row.body == "queued while down"
    assert row.sender_name == "Camp"
    assert row.seen_at == DateTime.truncate(seen, :second)
    assert row.external_id =~ "mc-ch-0-1700000000-"
  end

  test "meshtastic Primary backfill dedups on packet id" do
    attrs = %{
      channel_idx: 0,
      body: "trail ping",
      from_ref: "aabbccdd",
      external_id: 99,
      meta: %{id: 99, rx_time: 1_700_000_100}
    }

    assert {:ok, row} = Messages.maybe_record_meshtastic_channel(attrs)
    assert row.external_id == "mt-99"
    assert row.channel_name == "Primary"
    assert row.seen_at == DateTime.from_unix!(1_700_000_100)
    assert {:ok, :duplicate} = Messages.maybe_record_meshtastic_channel(attrs)
  end

  test "meshtastic MessageStore backfill can force-record a non-Primary slot" do
    assert {:ok, row} =
             Messages.maybe_record_meshtastic_channel(%{
               channel_idx: 3,
               body: "from the radio log",
               from_ref: "9eecc24c",
               force: true,
               meta: %{source: "message_store"}
             })

    assert row.network == "meshtastic"
    assert row.body == "from the radio log"
    assert row.channel_idx == 3
  end
end
