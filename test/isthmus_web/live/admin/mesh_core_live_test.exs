defmodule IsthmusWeb.Admin.MeshCoreLiveTest do
  use IsthmusWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Isthmus.Accounts
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

  test "renders detected devices strip and rescan control", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/meshcore")

    assert has_element?(view, "#detected-devices-card")
    assert has_element?(view, "#rescan-devices-btn")
    assert has_element?(view, "#bridge-card")
    refute has_element?(view, "#companion-radio-card")
    refute has_element?(view, "#repeater-radio-card")
  end

  test "rescan flashes a result", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/meshcore")

    view |> element("#rescan-devices-btn") |> render_click()
    assert render(view) =~ "Rescanned"
  end
end
