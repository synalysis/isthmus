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

  test "lists adverts and filters by network", %{conn: conn} do
    rns = String.duplicate("ab", 16)
    mc = String.duplicate("cd", 32)

    {:ok, _} =
      Sightings.record(%{
        network: "reticulum",
        direction: "in",
        identity_ref: rns,
        meta: %{"name" => "Alice"}
      })

    {:ok, _} = Sightings.record(%{network: "meshcore", direction: "in", identity_ref: mc})

    {:ok, view, _html} = live(conn, ~p"/admin/adverts")

    assert has_element?(view, "#advert-reticulum-#{rns}")
    assert has_element?(view, "#advert-meshcore-#{mc}")
    assert render(view) =~ "Alice"

    view
    |> element("#adverts-filter")
    |> render_change(%{"network" => "reticulum"})

    assert has_element?(view, "#advert-reticulum-#{rns}")
    refute has_element?(view, "#advert-meshcore-#{mc}")
    assert render(view) =~ "Alice"
  end
end
