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

    {:ok, _unrelated} =
      Sightings.record(%{
        network: "reticulum",
        direction: "in",
        identity_ref: String.duplicate("ee", 16),
        hops: 1
      })

    linked = Sightings.list_recent_for_tunnels(20)
    assert Enum.any?(linked, &(&1.id == sighting.id))
    refute Enum.any?(linked, &(&1.identity_ref == String.duplicate("ee", 16)))
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

  test "nostr carrier converts npub peer_ref to hex" do
    alias Isthmus.Nostr.Bech32

    raw = :crypto.strong_rand_bytes(32)
    hex = Base.encode16(raw, case: :lower)
    npub = Bech32.encode_npub(raw)

    {:ok, peer} =
      Tunnel.create_peer(%{
        name: "Nostr peer",
        peer_ref: npub,
        payload_network: "meshcore",
        carrier_network: "nostr"
      })

    assert peer.peer_ref == hex

    {:ok, peer} = Tunnel.update_peer(peer, %{peer_ref: String.upcase(hex)})
    assert peer.peer_ref == hex
  end

  test "nostr carrier rejects invalid peer_ref" do
    assert {:error, changeset} =
             Tunnel.create_peer(%{
               name: "Bad nostr",
               peer_ref: "not-an-npub",
               payload_network: "meshcore",
               carrier_network: "nostr"
             })

    assert "must be a valid npub or 64-char hex pubkey" in errors_on(changeset).peer_ref
  end

  test "a shared pairing code derives a matching tunnel_id on both sides" do
    expected = Tunnel.tunnel_id_from_code("Lobby Link")

    {:ok, side_a} =
      Tunnel.create_peer(%{
        name: "A",
        peer_ref: @ref,
        payload_network: "meshcore",
        carrier_network: "reticulum",
        pairing_code: "Lobby Link"
      })

    # The far side enters the same code with different casing/whitespace.
    derived_b = Tunnel.tunnel_id_from_code("  lobby link  ")

    assert side_a.tunnel_id == expected
    assert derived_b == expected
    assert String.match?(side_a.tunnel_id, ~r/\A[0-9a-f]{32}\z/)
  end

  test "different pairing codes derive different tunnel_ids" do
    refute Tunnel.tunnel_id_from_code("island-b") == Tunnel.tunnel_id_from_code("island-c")
  end

  test "an explicit tunnel_id overrides the pairing code" do
    {:ok, peer} =
      Tunnel.create_peer(%{
        name: "Explicit",
        peer_ref: @ref,
        payload_network: "meshcore",
        carrier_network: "reticulum",
        tunnel_id: "6d105c6ddcf9f9225ecd9f428520ca72",
        pairing_code: "ignored"
      })

    assert peer.tunnel_id == "6d105c6ddcf9f9225ecd9f428520ca72"
  end

  test "update_peer edits fields but keeps the tunnel_id when no code is given" do
    {:ok, peer} =
      Tunnel.create_peer(%{
        name: "Before",
        peer_ref: @ref,
        payload_network: "reticulum",
        carrier_network: "reticulum"
      })

    original_id = peer.tunnel_id

    {:ok, updated} =
      Tunnel.update_peer(peer, %{"name" => "After", "payload_network" => "meshcore"})

    assert updated.name == "After"
    assert updated.payload_network == "meshcore"
    assert updated.tunnel_id == original_id
  end

  test "update_peer re-derives the tunnel_id from a new pairing code" do
    {:ok, peer} =
      Tunnel.create_peer(%{
        name: "Repair",
        peer_ref: @ref,
        payload_network: "meshcore",
        carrier_network: "reticulum"
      })

    {:ok, updated} = Tunnel.update_peer(peer, %{"pairing_code" => "Fresh Pair"})

    assert updated.tunnel_id == Tunnel.tunnel_id_from_code("Fresh Pair")
    refute updated.tunnel_id == peer.tunnel_id
  end

  test "delete_peer removes the peer" do
    {:ok, peer} =
      Tunnel.create_peer(%{
        name: "Doomed",
        peer_ref: @ref,
        payload_network: "reticulum",
        carrier_network: "reticulum"
      })

    assert {:ok, _} = Tunnel.delete_peer(peer)
    assert Tunnel.list_peers() == []
  end
end
