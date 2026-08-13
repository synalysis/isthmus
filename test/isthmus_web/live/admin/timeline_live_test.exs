defmodule IsthmusWeb.Admin.TimelineLiveTest do
  use IsthmusWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Isthmus.Accounts
  alias Isthmus.Announce.Governor
  alias Isthmus.Announce.Sightings
  alias Isthmus.Gateway
  alias Isthmus.Nostr.Bech32
  alias Isthmus.Repo

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

  test "lists mixed kinds and toggles sighting/governor/gateway filters", %{conn: conn} do
    {:ok, sighting} =
      Sightings.record(%{
        network: "reticulum",
        direction: "in",
        identity_ref: String.duplicate("ab", 16),
        meta: %{"source" => "announce"}
      })

    {:ok, gateway} =
      Gateway.log(%{
        direction: "bridge",
        from_network: "admin",
        to_network: "meshcore",
        from_ref: "admin",
        to_ref: String.duplicate("cd", 32),
        body: "",
        status: "delivered"
      })

    {:ok, governor} =
      %Governor.Event{}
      |> Governor.Event.changeset(%{
        network: "meshcore",
        class: "announce",
        identity_key: "drop-me",
        action: "drop",
        reason: "rate",
        seen_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.insert()

    {:ok, view, _html} = live(conn, ~p"/admin/timeline")

    assert has_element?(view, "#timeline-filter")
    assert has_element?(view, "#filter-sighting")
    assert has_element?(view, "#filter-governor")
    assert has_element?(view, "#filter-gateway")
    refute has_element?(view, "#filter-all-kinds")

    assert has_element?(view, "#timeline-sighting-#{sighting.id}")
    assert has_element?(view, "#timeline-gateway-#{gateway.id}")
    assert has_element?(view, "#timeline-governor-#{governor.id}")

    view |> element("#filter-gateway") |> render_click()
    refute has_element?(view, "#timeline-gateway-#{gateway.id}")
    assert has_element?(view, "#timeline-sighting-#{sighting.id}")
    assert has_element?(view, "#timeline-governor-#{governor.id}")
    assert has_element?(view, "#filter-all-kinds")

    view |> element("#filter-sighting") |> render_click()
    view |> element("#filter-governor") |> render_click()
    refute has_element?(view, "#timeline-sighting-#{sighting.id}")
    refute has_element?(view, "#timeline-governor-#{governor.id}")
    assert has_element?(view, "#ops-timeline", "No kinds selected.")

    view |> element("#filter-all-kinds") |> render_click()
    assert has_element?(view, "#timeline-sighting-#{sighting.id}")
    assert has_element?(view, "#timeline-gateway-#{gateway.id}")
    assert has_element?(view, "#timeline-governor-#{governor.id}")
  end
end
