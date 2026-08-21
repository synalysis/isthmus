defmodule IsthmusWeb.Admin.FirmwareOfferTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Isthmus.Networks.Firmware.Catalog
  alias IsthmusWeb.Admin.FirmwareOffer

  test "offer shows download for the latest companion UF2" do
    html =
      render_component(&FirmwareOffer.usb_firmware_offer/1, %{
        id: "usb-firmware-offer-wio",
        device_id: "usb:2886:1667:WIO1",
        kind: :companion,
        board_id: :wio_tracker_l1,
        running_version: "1.16.0",
        connected: true,
        catalog: Catalog.fixture_snapshot(),
        source: nil
      })

    assert html =~ "Running 1.16.0"
    assert html =~ "1.17.1"
    assert html =~ "WioTrackerL1_companion_radio_usb"
    assert html =~ ~s(id="usb-firmware-offer-wio-download")
    assert html =~ ~s(id="usb-firmware-offer-wio-write")
    assert html =~ "Write firmware"
    assert html =~ ~s(id="usb-firmware-offer-wio-kind")
    assert html =~ ~s(id="usb-firmware-offer-wio-install")
    assert html =~ "Install 1.17.1"
  end

  test "offer asks to Flash when replacing Meshtastic with MeshCore companion" do
    html =
      render_component(&FirmwareOffer.usb_firmware_offer/1, %{
        id: "usb-firmware-offer-replace",
        device_id: "usb:10c4:ea60:HT1",
        kind: :companion,
        running_kind: :meshtastic,
        board_id: :heltec_v3,
        running_version: "2.7.15.567b8ea",
        connected: true,
        catalog: Catalog.fixture_snapshot(),
        source: nil
      })

    assert html =~ "Running Meshtastic 2.7.15.567b8ea"
    assert html =~ "Flash MeshCore companion"
    assert html =~ ~s(id="usb-firmware-offer-replace-install")
    refute html =~ "Install 1.17.1"
  end

  test "offer shows Install for Heltec Meshtastic" do
    html =
      render_component(&FirmwareOffer.usb_firmware_offer/1, %{
        id: "usb-firmware-offer-heltec",
        device_id: "usb:10c4:ea60:HT1",
        kind: :meshtastic,
        board_id: :heltec_v3,
        running_version: "2.7.15.567b8ea",
        connected: true,
        catalog: Catalog.fixture_snapshot(),
        source: nil
      })

    assert html =~ ~s(id="usb-firmware-offer-heltec-install")
    assert html =~ "Install 2.7.26.54e0d8d"
  end

  test "newer? is true only when connected and behind" do
    catalog = Catalog.fixture_snapshot()

    device = %{
      id: "usb:2886:1667:WIO1",
      vendor_id: 0x2886,
      product_id: 0x1667,
      kind: :companion,
      firmware_version: "1.16.0",
      active_companion?: true,
      ports: [%{role: :companion}]
    }

    assert FirmwareOffer.newer?(device, %{}, catalog)

    refute FirmwareOffer.newer?(%{device | firmware_version: "1.17.1"}, %{}, catalog)
    refute FirmwareOffer.newer?(%{device | active_companion?: false}, %{}, catalog)
    refute FirmwareOffer.newer?(%{device | firmware_version: nil}, %{}, catalog)
  end

  test "island without a published build explains the recipe" do
    html =
      render_component(&FirmwareOffer.usb_firmware_offer/1, %{
        id: "usb-firmware-offer-island",
        device_id: "usb:2886:1667:WIO1",
        kind: :island,
        board_id: :wio_tracker_l1,
        running_version: nil,
        connected: true,
        catalog: Catalog.fixture_snapshot(),
        source: nil
      })

    assert html =~ "No published island-bridge build"
    refute html =~ "-install"
  end

  test "offer shows a UF2 copy error and a retry button" do
    html =
      render_component(&FirmwareOffer.usb_firmware_offer/1, %{
        id: "usb-firmware-offer-error",
        device_id: "usb:2886:1667:WIO1",
        kind: :companion,
        board_id: :wio_tracker_l1,
        running_version: "1.16.0",
        connected: true,
        catalog: Catalog.fixture_snapshot(),
        source: nil,
        flash_job: %{
          device_id: "usb:2886:1667:WIO1",
          phase: :error,
          error: :uf2_copy_timeout
        }
      })

    assert html =~ ~s(id="usb-firmware-offer-error-progress")
    assert html =~ "Copy to the bootloader volume timed out"
    assert html =~ "Retry Install"
  end
end
