defmodule Isthmus.Tunnel.RoutingTest do
  use Isthmus.DataCase, async: false

  alias Isthmus.Announce.Sightings
  alias Isthmus.Tunnel

  setup do
    peer_ref = "eeff" <> String.duplicate("11", 30)

    {:ok, fast} =
      Tunnel.create_peer(%{
        name: "Fast tunnel",
        peer_ref: peer_ref,
        payload_network: "reticulum",
        carrier_network: "meshcore"
      })

    {:ok, slow} =
      Tunnel.create_peer(%{
        name: "Slow tunnel",
        peer_ref: peer_ref,
        payload_network: "reticulum",
        carrier_network: "reticulum"
      })

    %{peer_ref: peer_ref, fast: fast, slow: slow}
  end

  test "best_peer prefers fewer hops", %{peer_ref: peer_ref, fast: fast, slow: slow} do
    _ =
      Sightings.record(%{
        network: "meshcore",
        direction: "out",
        identity_ref: peer_ref,
        tunnel_id: slow.tunnel_id,
        hops: 4,
        latency_ms: 50
      })

    _ =
      Sightings.record(%{
        network: "meshcore",
        direction: "out",
        identity_ref: peer_ref,
        tunnel_id: fast.tunnel_id,
        hops: 1,
        latency_ms: 200
      })

    assert %Tunnel.Peer{id: best_id} = Tunnel.best_peer(peer_ref)
    assert best_id == fast.id
  end

  test "best_peer breaks ties on latency", %{peer_ref: peer_ref, fast: fast, slow: slow} do
    _ =
      Sightings.record(%{
        network: "meshcore",
        direction: "out",
        identity_ref: peer_ref,
        tunnel_id: slow.tunnel_id,
        hops: 1,
        latency_ms: 500
      })

    _ =
      Sightings.record(%{
        network: "meshcore",
        direction: "out",
        identity_ref: peer_ref,
        tunnel_id: fast.tunnel_id,
        hops: 1,
        latency_ms: 80
      })

    assert %Tunnel.Peer{id: best_id} = Tunnel.best_peer(peer_ref)
    assert best_id == fast.id
  end

  test "send_payload_best enqueues on best peer", %{peer_ref: peer_ref, fast: fast} do
    _ =
      Sightings.record(%{
        network: "meshcore",
        direction: "out",
        identity_ref: peer_ref,
        tunnel_id: fast.tunnel_id,
        hops: 0,
        latency_ms: 10
      })

    assert {:ok, msg} = Tunnel.send_payload_best(peer_ref, "hello")
    assert msg.channel == "tunnel:#{fast.tunnel_id}"
  end
end
