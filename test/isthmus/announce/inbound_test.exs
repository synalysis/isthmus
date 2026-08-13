defmodule Isthmus.Announce.InboundTest do
  use Isthmus.DataCase, async: false

  alias Isthmus.Announce.Inbound
  alias Isthmus.Announce.Sightings

  test "records a named reticulum announce sighting" do
    ref = String.duplicate("ab", 16)
    assert :ok = Inbound.record_reticulum(ref, "Alice")

    assert %{network: "reticulum", direction: "in", meta: meta} =
             Sightings.best_for("reticulum", ref)

    assert meta["name"] == "Alice"
    assert meta["source"] == "announce"
  end

  test "throttles repeated announces within the dedup window" do
    ref = String.duplicate("cd", 16)
    assert :ok = Inbound.record_reticulum(ref, "Bob")
    assert :ok = Inbound.record_reticulum(ref, "Bob")

    rows =
      Sightings.recent_for_network("reticulum", 50)
      |> Enum.filter(&(&1.identity_ref == ref))

    assert length(rows) == 1
  end

  test "ignores blank destination hashes" do
    assert :ok = Inbound.record_reticulum("", "Nobody")
    assert Sightings.recent_for_network("reticulum", 50) == []
  end

  test "upgrades a recent nameless meshcore sighting when a name is learned" do
    ref = String.duplicate("ef", 32)
    assert :ok = Inbound.record("meshcore", ref, nil, "push_advert")
    assert %{meta: meta1} = Sightings.best_for("meshcore", ref)
    refute Map.has_key?(meta1, "name")

    assert :ok = Inbound.record("meshcore", ref, "Camp Node", "contact")
    assert %{meta: %{"name" => "Camp Node"}} = Sightings.best_for("meshcore", ref)
  end

  test "honors explicit direction in extra opts" do
    ref = String.duplicate("aa", 32)

    assert :ok =
             Inbound.record("meshcore", ref, "Remote", "tunnel_advert", %{direction: "out"})

    assert %{direction: "out", meta: meta} = Sightings.best_for("meshcore", ref)
    assert meta["source"] == "tunnel_advert"
    refute Map.has_key?(meta, "direction")
  end

  test "handle_reticulum records lxmf.delivery announces with names" do
    ref = String.duplicate("11", 16)

    assert :ok =
             Inbound.handle_reticulum(%{
               "destination_hash" => ref,
               "name" => "Bob",
               "aspect" => "lxmf.delivery"
             })

    assert %{meta: %{"name" => "Bob"}} = Sightings.best_for("reticulum", ref)
  end

  test "handle_reticulum records hops from the sidecar announce" do
    ref = String.duplicate("33", 16)

    assert :ok =
             Inbound.handle_reticulum(%{
               "destination_hash" => ref,
               "name" => "Carol",
               "aspect" => "lxmf.delivery",
               "hops" => 2
             })

    assert %{hops: 2, meta: %{"name" => "Carol"}} = Sightings.best_for("reticulum", ref)
  end

  test "upgrades hops on a recent nameless reticulum sighting" do
    ref = String.duplicate("44", 16)
    assert :ok = Inbound.record("reticulum", ref, "Dana", "announce")
    assert %{hops: nil} = Sightings.best_for("reticulum", ref)

    assert :ok =
             Inbound.handle_reticulum(%{
               "destination_hash" => ref,
               "name" => "Dana",
               "aspect" => "lxmf.delivery",
               "hops" => 3
             })

    assert %{hops: 3} = Sightings.best_for("reticulum", ref)
  end

  test "upgrades hops on a recent meshcore advert when contact path is learned" do
    ref = String.duplicate("55", 32)
    assert :ok = Inbound.record("meshcore", ref, nil, "push_advert")
    assert %{hops: nil} = Sightings.best_for("meshcore", ref)

    assert :ok = Inbound.record("meshcore", ref, "Camp Node", "contact", %{hops: 2})
    assert %{hops: 2, meta: %{"name" => "Camp Node"}} = Sightings.best_for("meshcore", ref)
  end

  test "handle_reticulum ignores isthmus.tunnel announces without names" do
    ref = String.duplicate("22", 16)

    assert :ok =
             Inbound.handle_reticulum(%{
               "destination_hash" => ref,
               "name" => nil,
               "aspect" => "isthmus.tunnel"
             })

    assert Sightings.best_for("reticulum", ref) == nil
  end

  test "records a named meshtastic nodeinfo sighting with hops" do
    ref = "deadbeef"

    assert :ok =
             Inbound.record("meshtastic", ref, "Trail Node", "node_db", %{hops: 2, snr: 7.5})

    assert %{network: "meshtastic", hops: 2, snr: snr, meta: meta} =
             Sightings.best_for("meshtastic", ref)

    assert meta["name"] == "Trail Node"
    assert meta["source"] == "node_db"
    refute Map.has_key?(meta, "hops")
    refute Map.has_key?(meta, "snr")
    assert_in_delta snr, 7.5, 0.01
  end
end
