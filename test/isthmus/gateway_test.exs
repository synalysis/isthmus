defmodule Isthmus.GatewayTest do
  use Isthmus.DataCase, async: false

  alias Isthmus.Gateway

  test "stats aggregate forwards by status and route" do
    assert {:ok, _} =
             Gateway.log(%{
               direction: "bridge",
               from_network: "reticulum",
               to_network: "nostr",
               from_ref: "aaa",
               to_ref: "bbb",
               body: "",
               status: "delivered",
               meta: %{"body_bytes" => 42}
             })

    assert {:ok, _} =
             Gateway.log(%{
               direction: "bridge",
               from_network: "reticulum",
               to_network: "nostr",
               from_ref: "aaa",
               to_ref: "bbb",
               body: "",
               status: "failed",
               error: ":no_service_nsec",
               meta: %{"body_bytes" => 10}
             })

    assert {:ok, _} =
             Gateway.log(%{
               direction: "bridge",
               from_network: "meshcore",
               to_network: "reticulum",
               from_ref: "ccc",
               to_ref: "ddd",
               body: "",
               status: "dropped",
               error: "governor:rate"
             })

    stats = Gateway.stats()
    assert stats.total >= 3
    assert stats.last_24h >= 3
    assert Map.get(stats.by_status, "delivered", 0) >= 1
    assert Map.get(stats.by_status_24h, "failed", 0) >= 1

    assert Enum.any?(stats.by_route_24h, fn r ->
             r.from == "reticulum" and r.to == "nostr" and r.count >= 2
           end)
  end

  test "list_forward_log omits message content and exposes body_bytes" do
    assert {:ok, _} =
             Gateway.log(%{
               direction: "bridge",
               from_network: "nostr",
               to_network: "meshcore",
               from_ref: String.duplicate("ab", 32),
               to_ref: String.duplicate("cd", 32),
               body: "secret payload must not appear",
               status: "delivered",
               meta: %{"body_bytes" => 17}
             })

    [row | _] = Gateway.list_forward_log(5)
    assert row.body_bytes == 17
    refute Map.has_key?(row, :body)
    refute Map.has_key?(row, "body")
  end
end
