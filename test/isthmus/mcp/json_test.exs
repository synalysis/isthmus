defmodule Isthmus.MCP.JSONTest do
  use ExUnit.Case, async: true

  alias Isthmus.MCP.JSON

  test "redacts vault and channel secrets from structs" do
    encoded =
      JSON.encode(%{
        id: "g1",
        encrypted_private_material: "secret-bytes",
        auth_secret: "relay-auth",
        meshcore_channel_secret_enc: "enc",
        nested: %{secret_enc: "x", name: "ok"}
      })

    refute encoded =~ "secret-bytes"
    refute encoded =~ "relay-auth"
    assert encoded =~ "ok"
  end

  test "encodes datetimes and atoms as JSON" do
    {:ok, decoded} =
      %{at: ~U[2026-08-13 12:00:00Z], status: :online}
      |> JSON.encode()
      |> Jason.decode()

    assert decoded["at"] == "2026-08-13T12:00:00Z"
    assert decoded["status"] == "online"
  end
end
