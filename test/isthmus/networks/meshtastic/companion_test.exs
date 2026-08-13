defmodule Isthmus.Networks.Meshtastic.CompanionTest do
  use Isthmus.DataCase, async: false

  alias Isthmus.Networks.Meshtastic.Companion

  test "disconnect_unidentified is a no-op when no radio is online" do
    assert :ok = Companion.disconnect_unidentified()
  end

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

  test "set_settings fails when disconnected" do
    assert {:error, :not_connected} =
             Companion.set_settings(%{"device" => %{"buzzer_mode" => "disabled"}})
  end

  test "set_time fails when disconnected" do
    assert {:error, :not_connected} = Companion.set_time()
  end

  test "clear_channel fails when disconnected" do
    assert {:error, :not_connected} = Companion.clear_channel(2)
  end

  test "list_channels returns eight placeholder slots before a dump" do
    channels = Companion.list_channels()
    assert length(channels) == 8
    assert Enum.all?(channels, & &1.empty?)
  end

  test "list_health includes the primary companion" do
    health = Companion.health()
    listed = Companion.list_health()

    assert Enum.any?(listed, fn h -> h.status == health.status end)
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

  test "inject_inbound records node_db hops_away as hops" do
    Phoenix.PubSub.subscribe(Isthmus.PubSub, "announce:sightings")

    Companion.inject_inbound(:nodeinfo, %{
      node_id: "!ccddeeff",
      name: "Ridge",
      hops_away: 3
    })

    assert_receive {:sighting, _}, 1_000
    assert %{hops: 3} = Isthmus.Announce.Sightings.best_for("meshtastic", "ccddeeff")
  end
end
