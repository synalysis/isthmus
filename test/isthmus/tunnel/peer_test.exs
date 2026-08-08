defmodule Isthmus.Tunnel.PeerTest do
  use Isthmus.DataCase, async: false

  alias Isthmus.Announce.Sightings
  alias Isthmus.Tunnel

  @ref "6D105C6DDCF9F9225ECD9F428520CA72"

  test "create_peer stores peer_ref trimmed and downcased" do
    {:ok, peer} =
      Tunnel.create_peer(%{
        name: "Shouty",
        peer_ref: "  #{@ref}  ",
        payload_network: "reticulum",
        carrier_network: "reticulum"
      })

    assert peer.peer_ref == String.downcase(@ref)
  end

  test "update_peer normalizes peer_ref too" do
    {:ok, peer} =
      Tunnel.create_peer(%{
        name: "Renamed",
        peer_ref: String.downcase(@ref),
        payload_network: "reticulum",
        carrier_network: "reticulum"
      })

    {:ok, peer} = Tunnel.update_peer(peer, %{peer_ref: " AABBCCDD "})
    assert peer.peer_ref == "aabbccdd"
  end

  test "a peer entered in uppercase is still found by candidate lookup" do
    {:ok, peer} =
      Tunnel.create_peer(%{
        name: "Uppercase entry",
        peer_ref: @ref,
        payload_network: "reticulum",
        carrier_network: "reticulum"
      })

    assert [%Tunnel.Peer{id: found}] = Tunnel.candidates(String.downcase(@ref))
    assert found == peer.id
    assert %Tunnel.Peer{id: ^found} = Tunnel.best_peer(String.downcase(@ref))
  end

  test "sightings link to a peer entered in uppercase" do
    {:ok, peer} =
      Tunnel.create_peer(%{
        name: "Sighted",
        peer_ref: @ref,
        payload_network: "reticulum",
        carrier_network: "reticulum"
      })

    # Announces arrive with lowercase hex refs.
    {:ok, sighting} =
      Sightings.record(%{
        network: "reticulum",
        direction: "in",
        identity_ref: String.downcase(@ref),
        hops: 2
      })

    assert sighting.tunnel_id == peer.tunnel_id
  end

  test "a blank peer_ref is still rejected after trimming" do
    assert {:error, changeset} =
             Tunnel.create_peer(%{
               name: "Blank",
               peer_ref: "   ",
               payload_network: "reticulum",
               carrier_network: "reticulum"
             })

    assert "can't be blank" in errors_on(changeset).peer_ref
  end
end
