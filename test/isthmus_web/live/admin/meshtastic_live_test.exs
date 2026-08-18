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
    assert has_element?(view, "#scan-bluetooth-btn")
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
    refute has_element?(view, "#meshtastic-send-channel-modal")
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

  test "Primary send modal opens and reports when the radio is offline", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/meshtastic")

    refute has_element?(view, "#meshtastic-send-channel-modal")

    render_click(view, "open_send_channel", %{"port" => "/dev/ttyTEST", "channel_idx" => "0"})

    assert has_element?(view, "#meshtastic-send-channel-modal")
    assert has_element?(view, "#meshtastic-send-channel-form")
    assert render(view) =~ "Send to Primary"

    view
    |> form("#meshtastic-send-channel-form", %{"body" => "hello primary"})
    |> render_submit()

    assert render(view) =~ "Try Send again"
  end

  test "Bluetooth scan results offer a connect form", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/meshtastic")

    send(
      view.pid,
      {:ble_scan_done,
       {:ok,
        [
          %{
            address: "11:22:33:44:55:66",
            name: "Meshtastic_Andreas",
            rssi: -50,
            kind: :meshtastic
          },
          %{address: "AA:BB:CC:DD:EE:FF", name: "MeshCore-1", rssi: -40, kind: :meshcore}
        ]}}
    )

    assert has_element?(view, "#ble-scan-results")
    assert render(view) =~ "existing Bluetooth bond"
    assert render(view) =~ "come back after a server restart"
    assert has_element?(view, "#ble-connect-11-22-33-44-55-66")
    refute has_element?(view, "#ble-pin-11-22-33-44-55-66")
    refute has_element?(view, "#ble-connect-AA-BB-CC-DD-EE-FF")
  end

  test "Scan Bluetooth disables while a scan is running", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/meshtastic")

    # Assert the click reply, not a later render: without a radio the scan Task
    # finishes immediately and has_element?/2 would see the button enabled again.
    html = view |> element("#scan-bluetooth-btn") |> render_click()
    assert html =~ ~r/id="scan-bluetooth-btn"[^>]*\bdisabled\b/
  end

  test "Bluetooth PIN modal opens after the radio requests a PIN", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/meshtastic")

    send(
      view.pid,
      {:ble_pin_request, %{address: "11:22:33:44:55:66", name: "Meshtastic_Andreas"}}
    )

    assert has_element?(view, "#ble-pin-modal")
    assert has_element?(view, "#ble-pin-form")
    assert has_element?(view, "#ble-pin-input")
    assert render(view) =~ "Meshtastic_Andreas"
  end
end
