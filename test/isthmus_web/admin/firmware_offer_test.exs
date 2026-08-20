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
  end
end
