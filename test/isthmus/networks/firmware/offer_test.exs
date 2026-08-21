defmodule Isthmus.Networks.Firmware.OfferTest do
  use ExUnit.Case, async: true

  alias Isthmus.Networks.Firmware.Board
  alias Isthmus.Networks.Firmware.Catalog
  alias Isthmus.Networks.Firmware.Offer

  test "guesses Wio Tracker L1 from USB identity" do
    assert Board.guess(%{vendor_id: 0x2886, product_id: 0x1667}) == :wio_tracker_l1
  end

  test "Wio companion matches the USB UF2" do
    snap = Catalog.fixture_snapshot()
    offer = Offer.lookup(:wio_tracker_l1, :companion, snap)

    assert offer.version == "1.17.1"
    assert offer.filename =~ "WioTrackerL1_companion_radio_usb"
    assert offer.url =~ "WioTrackerL1_companion_radio_usb"
  end

  test "Wio island is nil when the island catalog is empty" do
    snap = Catalog.fixture_snapshot()
    assert Offer.lookup(:wio_tracker_l1, :island, snap) == nil
  end

  test "Heltec RNode matches the official zip" do
    snap = Catalog.fixture_snapshot()
    offer = Offer.lookup(:heltec_v3, :rnode, snap)

    assert offer.filename == "rnode_firmware_heltec32v3.zip"
    assert offer.version == "1.86"
  end

  test "Meshtastic falls back to the release zip" do
    snap = Catalog.fixture_snapshot()
    offer = Offer.lookup(:wio_tracker_l1, :meshtastic, snap)

    assert offer.filename == "firmware-2.7.26.54e0d8d.zip"
    assert offer.version == "2.7.26.54e0d8d"
  end

  test "Heltec Meshtastic also falls back to the zip when GitHub lists only the archive" do
    snap = Catalog.fixture_snapshot()
    offer = Offer.lookup(:heltec_v3, :meshtastic, snap)
    assert offer.filename == "firmware-2.7.26.54e0d8d.zip"
    assert Board.programmer(:heltec_v3) == :esptool
  end

  test "Meshtastic hyphen asset names match Heltec V3" do
    snap = %{
      meshtastic: %{
        version: "2.7.26.54e0d8d",
        html_url: "https://example.test",
        assets: [
          %{
            name: "firmware-heltec-v3-2.7.26.54e0d8d.bin",
            url: "https://example.test/firmware-heltec-v3-2.7.26.54e0d8d.bin"
          }
        ]
      }
    }

    offer = Offer.lookup(:heltec_v3, :meshtastic, snap)
    assert offer.filename == "firmware-heltec-v3-2.7.26.54e0d8d.bin"
  end

  test "status is newer_available when running is behind" do
    snap = Catalog.fixture_snapshot()
    offer = Offer.lookup(:wio_tracker_l1, :companion, snap)
    assert Offer.status("1.16.0", offer) == :newer_available
    assert Offer.status("1.17.1", offer) == :current
    assert Offer.status(nil, offer) == :unknown
  end
end
