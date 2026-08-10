defmodule Isthmus.Announce.KnownAddressesTest do
  use Isthmus.DataCase, async: false

  alias Isthmus.Announce.KnownAddresses
  alias Isthmus.Announce.Sightings

  test "reticulum suggestions come from recent sightings, newest first, deduped" do
    old = DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.truncate(:second)
    new = DateTime.utc_now() |> DateTime.truncate(:second)
    ref = String.duplicate("ab", 16)

    {:ok, _} =
      Sightings.record(%{network: "reticulum", direction: "in", identity_ref: ref, seen_at: old})

    {:ok, _} =
      Sightings.record(%{
        network: "reticulum",
        direction: "in",
        identity_ref: ref,
        seen_at: new,
        meta: %{"name" => "Alice"}
      })

    {:ok, _} =
      Sightings.record(%{
        network: "reticulum",
        direction: "in",
        identity_ref: String.duplicate("cd", 16)
      })

    suggestions = KnownAddresses.for_network("reticulum")

    # Deduped by ref; the newest (named) row wins for the duplicate.
    assert Enum.count(suggestions, &(&1.ref == ref)) == 1
    assert %{name: "Alice"} = Enum.find(suggestions, &(&1.ref == ref))
    assert Enum.any?(suggestions, &(&1.ref == String.duplicate("cd", 16)))
  end

  test "does not include other networks' sightings" do
    {:ok, _} =
      Sightings.record(%{
        network: "meshcore",
        direction: "in",
        identity_ref: String.duplicate("ef", 32)
      })

    refute Enum.any?(
             KnownAddresses.for_network("reticulum"),
             &(&1.ref == String.duplicate("ef", 32))
           )
  end

  test "unknown network yields no suggestions" do
    assert KnownAddresses.for_network("nostr") == []
    assert KnownAddresses.for_network("bogus") == []
  end
end
