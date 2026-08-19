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
    assert has_element?(view, "#mesh-contacts")
    assert has_element?(view, "#rescan-devices-btn")
    assert has_element?(view, "#scan-bluetooth-btn")
    refute has_element?(view, "#groups-channels")
    refute has_element?(view, "#companion-setup-card")
    refute has_element?(view, "#channel-bridge-detail")
    refute has_element?(view, "#channel-bridge-form")
    refute has_element?(view, "#meshcore-invite-modal")
    refute has_element?(view, "#synthetic-identities-card")
    refute has_element?(view, "#companion-channels-alert")
    refute has_element?(view, "#meshcore-radio-modal")
    refute has_element?(view, "#meshcore-radio-form")
    refute html =~ "Unassigned"
    refute html =~ "New group + private channel"
    refute html =~ "Groups and radio channels"
    assert html =~ "Island mesh traffic"
    assert html =~ "Contacts on the mesh"
  end

  test "rescan flashes a result", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/meshcore")

    view |> element("#rescan-devices-btn") |> render_click()
    assert render(view) =~ "Rescanned"
  end

  test "Bluetooth scan results offer a connect form", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/meshcore")

    send(
      view.pid,
      {:ble_scan_done, {:ok, [%{address: "AA:BB:CC:DD:EE:FF", name: "MeshCore-1", rssi: -42}]}}
    )

    assert has_element?(view, "#ble-scan-results")
    assert has_element?(view, "#ble-connect-AA-BB-CC-DD-EE-FF")
    assert has_element?(view, "#ble-pin-AA-BB-CC-DD-EE-FF")
  end

  test "Scan Bluetooth disables while a scan is running", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/meshcore")

    # Assert the click reply, not a later render: without a radio the scan Task
    # finishes immediately and has_element?/2 would see the button enabled again.
    html = view |> element("#scan-bluetooth-btn") |> render_click()
    assert html =~ ~r/id="scan-bluetooth-btn"[^>]*\bdisabled\b/
  end

  test "assign_usb_role persists a MeshCore companion role", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/meshcore")

    render_submit(view, "assign_usb_role", %{
      "path" => "/dev/ttyACM2",
      "serial" => "CP1",
      "vendor_id" => Integer.to_string(0x2886),
      "product_id" => Integer.to_string(0x802F),
      "role" => "companion"
    })

    html = render(view)
    assert html =~ "MeshCore companion"

    assert [%{"path" => "/dev/ttyACM2", "role" => "companion"}] =
             Isthmus.Networks.UsbAssignments.list()
  end

  test "assign_usb_firmware reports an unknown device", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/admin/meshcore")

    render_submit(view, "assign_usb_firmware", %{"device_id" => "missing", "kind" => "island"})
    assert render(view) =~ "Unknown device"
  end
end
