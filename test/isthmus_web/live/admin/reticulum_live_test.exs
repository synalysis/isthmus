defmodule IsthmusWeb.Admin.ReticulumLiveTest do
  use IsthmusWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Isthmus.Accounts
  alias Isthmus.FirmwareCatalogFixtures
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

  test "Isthmus config pane can add RNodeInterface", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/admin/reticulum")

    assert html =~ "Reticulum"
    refute has_element?(view, "#rns-iface-modal")
    refute has_element?(view, "#rns-iface-form")

    if has_element?(view, "#rns-config-editor") do
      assert has_element?(view, "#rns-rescan-rnodes")
      assert has_element?(view, "#rns-open-iface-modal")

      assert has_element?(view, "#rns-detected-rnodes-empty") or
               has_element?(view, "#rns-detected-rnodes")

      view |> element("#rns-open-iface-modal") |> render_click()
      assert has_element?(view, "#rns-iface-modal")
      assert has_element?(view, "#rns-iface-form")
      assert render(view) =~ "RNodeInterface"

      view |> element("#rns-close-iface-modal") |> render_click()
      refute has_element?(view, "#rns-iface-modal")
    end

    if has_element?(view, "#rns-status") do
      assert has_element?(view, "#rns-lxmf-destinations")
      assert render(view) =~ "Isthmus-owned"
      assert render(view) =~ "lxmf.delivery"
    end
  end

  test "detected Heltec RNode offers the latest zip and an update badge", %{conn: conn} do
    {previous, _detail} = FirmwareCatalogFixtures.seed_rnode_heltec(firmware_version: "1.80")

    on_exit(fn -> FirmwareCatalogFixtures.restore_discover_roles(previous) end)

    {:ok, view, _html} = live(conn, ~p"/admin/reticulum")

    if has_element?(view, "#rns-config-editor") do
      assert has_element?(view, "#refresh-firmware-catalog-btn")
      assert has_element?(view, "#usb-firmware-offer-rnode-ttyACM3")
      assert has_element?(view, "#usb-firmware-offer-rnode-ttyACM3-download")
      assert has_element?(view, "#rnode-ttyACM3-firmware-update")
      assert render(view) =~ "rnode_firmware_heltec32v3.zip"
    end
  end
end
