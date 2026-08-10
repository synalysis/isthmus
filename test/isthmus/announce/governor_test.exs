defmodule Isthmus.Announce.GovernorTest do
  use Isthmus.DataCase, async: false

  alias Isthmus.Announce.Governor

  test "dedups repeated announce keys" do
    key = "test-#{System.unique_integer()}"
    assert :ok = Governor.allow?(:announce, :reticulum, key)
    assert {:drop, :dedup} = Governor.allow?(:announce, :reticulum, key)
  end

  test "tunnel_data is budget-only (no per-tunnel TTL dedup)" do
    tid = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    assert :ok = Governor.allow?(:tunnel_data, :nostr, tid)
    assert :ok = Governor.allow?(:tunnel_data, :nostr, tid)
    assert :ok = Governor.allow?(:tunnel_data, :nostr, tid)
  end

  test "drops_summary collapses identical keys and keeps latest seen_at" do
    key = "collapse-#{System.unique_integer()}"

    assert :ok = Governor.allow?(:advert, :meshcore, key)
    assert {:drop, :dedup} = Governor.allow?(:advert, :meshcore, key)
    assert {:drop, :dedup} = Governor.allow?(:advert, :meshcore, key)

    rows = Governor.drops_summary(20)
    match = Enum.find(rows, &(&1.identity_key == key))

    assert match
    assert match.count >= 2
    assert match.reason == "dedup"
    assert match.network == "meshcore"
    assert %DateTime{} = match.seen_at
  end
end
