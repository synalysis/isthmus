defmodule Isthmus.Networks.Meshtastic.CompanionTest do
  use Isthmus.DataCase, async: false

  alias Isthmus.Networks.Meshtastic.Companion

  test "health is disabled when no Meshtastic radio is detected" do
    health = Companion.health()
    assert health.status == :disabled
    assert health.last_error =~ "no companion detected"
  end

  test "send_channel_text fails when disconnected" do
    assert {:error, :not_connected} = Companion.send_channel_text(1, "hi")
  end

  test "set_lora_config fails when disconnected" do
    assert {:error, :not_connected} =
             Companion.set_lora_config(%{
               "region" => "1",
               "mode" => "preset",
               "modem_preset" => "0"
             })
  end

  test "list_channels returns eight placeholder slots before a dump" do
    channels = Companion.list_channels()
    assert length(channels) == 8
    assert Enum.all?(channels, & &1.empty?)
  end

  test "inject_inbound publishes channel messages" do
    Phoenix.PubSub.subscribe(Isthmus.PubSub, "meshtastic:inbound")

    Companion.inject_inbound(:channel, %{
      channel_idx: 2,
      body: "from the trail",
      from_ref: "deadbeef"
    })

    assert_receive {:meshtastic_channel, attrs}, 1_000
    assert attrs.channel_idx == 2
    assert attrs.body == "from the trail"
    assert attrs.from_ref == "deadbeef"

    # PubSub handle_info casts ingest; two sync points drain both messages
    # before the sandbox owner exits.
    _ = :sys.get_state(Isthmus.Gateway.Translator)
    _ = :sys.get_state(Isthmus.Gateway.Translator)
  end

  test "inject_inbound records nodeinfo as a meshtastic sighting" do
    Phoenix.PubSub.subscribe(Isthmus.PubSub, "announce:sightings")

    Companion.inject_inbound(:nodeinfo, %{
      node_id: "!aabbccdd",
      name: "Trail Node",
      hops: 2,
      snr: 6.25
    })

    assert_receive {:sighting, _}, 1_000

    assert %{network: "meshtastic", hops: 2, meta: meta} =
             Isthmus.Announce.Sightings.best_for("meshtastic", "aabbccdd")

    assert meta["name"] == "Trail Node"
    assert meta["source"] == "nodeinfo"
  end
end
