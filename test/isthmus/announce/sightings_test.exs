defmodule Isthmus.Announce.SightingsTest do
  use Isthmus.DataCase, async: false

  alias Isthmus.Announce.Sighting
  alias Isthmus.Announce.Sightings

  test "record sets 24h expiry and normalizes identity_ref" do
    assert {:ok, row} =
             Sightings.record(%{
               network: "meshcore",
               direction: "in",
               identity_ref: "AABB" <> String.duplicate("CC", 30),
               hops: 2
             })

    assert row.identity_ref == String.downcase(row.identity_ref)
    assert DateTime.diff(row.expires_at, row.seen_at, :second) == Sighting.retention_seconds()
  end

  test "purge_expired removes old rows" do
    past = DateTime.utc_now() |> DateTime.add(-100, :second) |> DateTime.truncate(:second)

    assert {:ok, _} =
             Sightings.record(%{
               network: "reticulum",
               direction: "out",
               identity_ref: String.duplicate("ab", 16),
               seen_at: past,
               expires_at: DateTime.add(past, -1, :second)
             })

    assert Sightings.purge_expired() >= 1
    assert Sightings.list_recent(10) == []
  end

  test "best_for returns latest matching sighting" do
    ref = String.duplicate("cd", 16)
    t1 = DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.truncate(:second)
    t2 = DateTime.utc_now() |> DateTime.truncate(:second)

    assert {:ok, _} =
             Sightings.record(%{
               network: "reticulum",
               direction: "in",
               identity_ref: ref,
               hops: 3,
               seen_at: t1,
               expires_at: DateTime.add(t1, Sighting.retention_seconds(), :second)
             })

    assert {:ok, _} =
             Sightings.record(%{
               network: "reticulum",
               direction: "in",
               identity_ref: ref,
               hops: 1,
               seen_at: t2,
               expires_at: DateTime.add(t2, Sighting.retention_seconds(), :second)
             })

    assert %{hops: 1, seen_at: ^t2} = Sightings.best_for("reticulum", ref)
  end
end
