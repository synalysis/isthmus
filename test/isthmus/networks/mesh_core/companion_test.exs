defmodule Isthmus.Networks.MeshCore.CompanionTest do
  use Isthmus.DataCase, async: false

  alias Isthmus.Networks.MeshCore.Companion

  test "clear_channel fails when disconnected" do
    assert {:error, :not_connected} = Companion.clear_channel(2)
  end
end
