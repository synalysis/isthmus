defmodule IsthmusWeb.Admin.TunnelsLiveTest do
  use IsthmusWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Isthmus.Accounts
  alias Isthmus.Nostr.Bech32
  alias Isthmus.Tunnel

  setup %{conn: conn} do
    raw = :crypto.strong_rand_bytes(32)
    pubkey = Base.encode16(raw, case: :lower)
    npub = Bech32.encode_npub(raw)
    {:ok, _} = Accounts.add_admin(%{pubkey_hex: pubkey, npub: npub, label: "test"})

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> IsthmusWeb.UserAuth.log_in_user(%{pubkey_hex: pubkey, npub: npub})

    %{conn: conn}
  end

  test "path details render for an enabled peer", %{conn: conn} do
    {:ok, peer} =
      Tunnel.create_peer(%{
        name: "Diag peer",
        peer_ref: "aa" <> String.duplicate("bb", 31),
        payload_network: "meshtastic",
        carrier_network: "meshtastic"
      })

    {:ok, view, _html} = live(conn, ~p"/admin/tunnels")

    assert has_element?(view, "#peer-path-#{peer.id}")
    assert has_element?(view, "#peer-path-#{peer.id}", "Path details")
    assert has_element?(view, "#peer-path-#{peer.id}", "Their ref (peer_ref)")
    assert has_element?(view, "#peer-path-#{peer.id}", "Outbound:")
    assert has_element?(view, "#peer-path-#{peer.id}", "Inbound:")
  end

  test "reticulum peers show path request and announce actions", %{conn: conn} do
    {:ok, peer} =
      Tunnel.create_peer(%{
        name: "RNS peer",
        peer_ref: String.duplicate("ab", 16),
        payload_network: "reticulum",
        carrier_network: "reticulum"
      })

    {:ok, view, _html} = live(conn, ~p"/admin/tunnels")

    assert has_element?(view, "#peer-path-#{peer.id}")
    assert has_element?(view, "#request-path-#{peer.id}")
    assert has_element?(view, "#announce-tunnel-#{peer.id}")
  end

  test "governor drops section shows relative time", %{conn: conn} do
    key = "drop-ui-#{System.unique_integer()}"
    assert :ok = Isthmus.Announce.Governor.allow?(:advert, :meshcore, key)
    assert {:drop, :dedup} = Isthmus.Announce.Governor.allow?(:advert, :meshcore, key)

    {:ok, view, _html} = live(conn, ~p"/admin/tunnels")

    assert has_element?(view, "#governor-drops")
    assert render(view) =~ "ago"
    assert render(view) =~ "meshcore/advert"
  end

  test "shows tunnel-linked sightings and links to Adverts", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/admin/tunnels")

    assert html =~ "Tunnel-linked sightings"
    assert html =~ ~p"/admin/adverts"
    assert has_element?(view, "#tunnel-sightings")
  end
end
