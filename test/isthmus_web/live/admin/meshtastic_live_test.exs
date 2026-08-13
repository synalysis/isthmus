defmodule IsthmusWeb.Admin.MeshtasticLiveTest do
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

  test "renders connected radios without a separate groups section", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/admin/meshtastic")

    assert has_element?(view, "#connected-radios")
    assert has_element?(view, "#devices-empty")
    assert has_element?(view, "#rescan-meshtastic-btn")
    refute has_element?(view, "#groups-channels")
    refute has_element?(view, "#companion-setup-card")
    refute has_element?(view, "#channel-bridge-detail")
    refute has_element?(view, "#companion-status")
    refute has_element?(view, "#reconnect-meshtastic-btn")
    refute has_element?(view, "#meshtastic-settings-modal")
    refute has_element?(view, "#meshtastic-settings-form")
    refute has_element?(view, "#meshtastic-lora-modal")
    refute has_element?(view, "#meshtastic-lora-form")
    refute has_element?(view, "#meshtastic-invite-modal")
    refute has_element?(view, "#channel-bridge-form")
    refute has_element?(view, "#create-channel-on-group-btn")
    refute html =~ "New group + private channel"
    refute html =~ "Groups and radio channels"
    assert html =~ "Connected radios"
    assert html =~ "companion radios"
  end

  test "rescan flashes a result", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/meshtastic")

    view |> element("#rescan-meshtastic-btn") |> render_click()
    assert render(view) =~ "Rescanned"
  end
end
