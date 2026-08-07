defmodule Isthmus.PolicyTest do
  use Isthmus.DataCase, async: true

  alias Isthmus.Policy

  test "empty allow-list permits all directions" do
    assert :ok = Policy.allow_gateway_direction?("nostr", "reticulum")
  end

  test "deny-list blocks even when allow is empty" do
    {:ok, _} = Policy.put("gateway_deny_directions", ["nostr>meshcore"])
    assert {:drop, :direction_denied} = Policy.allow_gateway_direction?("nostr", "meshcore")
    assert :ok = Policy.allow_gateway_direction?("nostr", "reticulum")
  end

  test "non-empty allow-list restricts directions" do
    {:ok, _} = Policy.put("gateway_allow_directions", ["reticulum>nostr"])
    assert :ok = Policy.allow_gateway_direction?("reticulum", "nostr")
    assert {:drop, :direction_not_allowed} = Policy.allow_gateway_direction?("nostr", "reticulum")
  end
end
