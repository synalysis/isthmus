defmodule IsthmusWeb.Admin.AdvertsLiveTest do
  use IsthmusWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Isthmus.Accounts
  alias Isthmus.Announce.Sightings
  alias Isthmus.Nostr.Bech32

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

  test "lists adverts and toggles network filters", %{conn: conn} do
    rns = String.duplicate("ab", 16)
    mc = String.duplicate("cd", 32)

    {:ok, _} =
      Sightings.record(%{
        network: "reticulum",
        direction: "in",
        identity_ref: rns,
        meta: %{"name" => "Alice", "source" => "announce"}
      })

    {:ok, _} =
      Sightings.record(%{
        network: "meshcore",
        direction: "in",
        identity_ref: mc,
        meta: %{"source" => "bridge_advert", "name" => "Local Node"}
      })

    {:ok, view, _html} = live(conn, ~p"/admin/adverts")

    assert has_element?(view, "#admin-nav")
    assert has_element?(view, "#admin-nav-networks")
    assert has_element?(view, "#admin-nav-ops")
    assert has_element?(view, advert_sel("reticulum", rns))
    assert has_element?(view, advert_sel("meshcore", mc))
    assert has_element?(view, "#filter-meshcore")
    assert has_element?(view, "#filter-reticulum")
    assert has_element?(view, "#filter-nostr")
    html = render(view)
    assert html =~ "Alice"
    assert html =~ "MC bridge"
    assert html =~ "RNS"

    # Turn MeshCore off — only Reticulum remains.
    view |> element("#filter-meshcore") |> render_click()

    assert has_element?(view, advert_sel("reticulum", rns))
    refute has_element?(view, advert_sel("meshcore", mc))
    assert render(view) =~ "Alice"

    # Turn MeshCore back on.
    view |> element("#filter-meshcore") |> render_click()
    assert has_element?(view, advert_sel("meshcore", mc))

    # Filter by name.
    view |> element("#adverts-search-form") |> render_change(%{"q" => "alice"})
    assert has_element?(view, advert_sel("reticulum", rns))
    refute has_element?(view, advert_sel("meshcore", mc))

    # Filter by address fragment.
    view |> element("#adverts-search-form") |> render_change(%{"q" => String.slice(mc, 0, 8)})
    refute has_element?(view, advert_sel("reticulum", rns))
    assert has_element?(view, advert_sel("meshcore", mc))

    view |> element("#adverts-search-clear") |> render_click()
    assert has_element?(view, advert_sel("reticulum", rns))
    assert has_element?(view, advert_sel("meshcore", mc))
  end

  test "lists meshtastic nodeinfo sightings", %{conn: conn} do
    ref = "aabbccdd"

    {:ok, _} =
      Sightings.record(%{
        network: "meshtastic",
        direction: "in",
        identity_ref: ref,
        hops: 1,
        meta: %{"name" => "Trail Node", "source" => "nodeinfo"}
      })

    {:ok, view, html} = live(conn, ~p"/admin/adverts")

    assert has_element?(view, "#filter-meshtastic")
    assert has_element?(view, advert_sel("meshtastic", ref))
    assert html =~ "Trail Node"
    assert html =~ "NodeInfo"
    assert html =~ "!aabbccdd"

    view |> element("#filter-meshtastic") |> render_click()
    refute has_element?(view, advert_sel("meshtastic", ref))
  end

  test "deselected reticulum does not hide older meshcore adverts", %{conn: conn} do
    older = DateTime.utc_now() |> DateTime.add(-180, :second) |> DateTime.truncate(:second)
    mc = String.duplicate("11", 32)

    {:ok, _} =
      Sightings.record(%{
        network: "meshcore",
        direction: "in",
        identity_ref: mc,
        seen_at: older,
        expires_at: DateTime.add(older, 86_400, :second),
        meta: %{"source" => "bridge_advert", "name" => "Camp Node"}
      })

    # Flood newer Reticulum rows past the Adverts window size (200).
    for i <- 1..200 do
      ref = Base.encode16(<<i::128>>, case: :lower)

      {:ok, _} =
        Sightings.record(%{
          network: "reticulum",
          direction: "in",
          identity_ref: ref,
          meta: %{"source" => "announce"}
        })
    end

    {:ok, view, _html} = live(conn, ~p"/admin/adverts")

    # With all networks on, MeshCore can fall outside the mixed newest-200.
    # Deselecting Reticulum must still surface it via a network-scoped query.
    view |> element("#filter-reticulum") |> render_click()
    view |> element("#filter-nostr") |> render_click()

    assert has_element?(view, advert_sel("meshcore", mc))
    assert render(view) =~ "Camp Node"
  end

  test "text filter finds meshcore while reticulum is selected", %{conn: conn} do
    older = DateTime.utc_now() |> DateTime.add(-120, :second) |> DateTime.truncate(:second)
    mobby = String.duplicate("aa", 32)

    {:ok, _} =
      Sightings.record(%{
        network: "meshcore",
        direction: "in",
        identity_ref: mobby,
        seen_at: older,
        expires_at: DateTime.add(older, 86_400, :second),
        meta: %{"source" => "bridge_advert", "name" => "Mobby"}
      })

    for i <- 1..200 do
      ref = Base.encode16(<<i::128>>, case: :lower)

      {:ok, _} =
        Sightings.record(%{
          network: "reticulum",
          direction: "in",
          identity_ref: ref,
          meta: %{"source" => "announce", "name" => "RNS #{i}"}
        })
    end

    {:ok, view, _html} = live(conn, ~p"/admin/adverts")

    # All networks remain selected (including Reticulum).
    view |> element("#adverts-search-form") |> render_change(%{"q" => "mob"})

    assert has_element?(view, advert_sel("meshcore", mobby))
    assert render(view) =~ "Mobby"
  end

  test "text filter does not leave ghost rows for duplicate identities", %{conn: conn} do
    mobby = String.duplicate("aa", 32)
    synthetic = String.duplicate("bb", 32)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, _} =
      Sightings.record(%{
        network: "meshcore",
        direction: "in",
        identity_ref: mobby,
        meta: %{"source" => "bridge_advert", "name" => "Mobby"}
      })

    for offset <- [0, -60, -120] do
      seen = DateTime.add(now, offset, :second)

      {:ok, _} =
        Sightings.record(%{
          network: "meshcore",
          direction: "out",
          identity_ref: synthetic,
          seen_at: seen,
          expires_at: DateTime.add(seen, 86_400, :second),
          meta: %{"source" => "synthetic_advert", "name" => "Isthmus Test"}
        })
    end

    {:ok, view, _html} = live(conn, ~p"/admin/adverts")
    view |> element("#filter-reticulum") |> render_click()
    view |> element("#filter-nostr") |> render_click()

    # Duplicate synthetic sightings collapse to one row.
    html = render(view)
    assert length(Regex.scan(~r/data-ref="#{synthetic}"/, html)) == 1

    view |> element("#adverts-search-form") |> render_change(%{"q" => "mo"})
    assert has_element?(view, advert_sel("meshcore", mobby))
    refute has_element?(view, advert_sel("meshcore", synthetic))

    view |> element("#adverts-search-form") |> render_change(%{"q" => "mobz"})
    refute has_element?(view, advert_sel("meshcore", mobby))
    refute has_element?(view, advert_sel("meshcore", synthetic))
    assert render(view) =~ "No adverts match this filter"

    view |> element("#adverts-search-form") |> render_change(%{"q" => "mobby"})
    assert has_element?(view, advert_sel("meshcore", mobby))
    refute has_element?(view, advert_sel("meshcore", synthetic))
  end

  defp advert_sel(network, ref), do: ~s(tr[data-network="#{network}"][data-ref="#{ref}"])
end
