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
end
