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

  test "renders purpose-first MeshCore sections", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/admin/meshcore")

    assert has_element?(view, "#connected-radios")
    assert has_element?(view, "#island-mesh")
    assert has_element?(view, "#groups-channels")
    assert has_element?(view, "#mesh-contacts")
    assert has_element?(view, "#rescan-devices-btn")
    refute has_element?(view, "#synthetic-identities-card")
    refute has_element?(view, "#companion-channels-alert")
    refute html =~ "Unassigned"
    assert html =~ "Island mesh traffic"
    assert html =~ "Contacts on the mesh"
  end

  test "companion setup card when companion offline", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/meshcore")

    assert has_element?(view, "#companion-setup-card")
  end

  test "rescan flashes a result", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/meshcore")

    view |> element("#rescan-devices-btn") |> render_click()
    assert render(view) =~ "Rescanned"
  end
end
