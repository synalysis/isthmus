defmodule Isthmus.Announce.GovernorTest do
  use Isthmus.DataCase, async: false

  alias Isthmus.Announce.Governor

  test "dedups repeated announce keys" do
    key = "test-#{System.unique_integer()}"
    assert :ok = Governor.allow?(:announce, :reticulum, key)
    assert {:drop, :dedup} = Governor.allow?(:announce, :reticulum, key)
  end
end
