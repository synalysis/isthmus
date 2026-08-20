defmodule Isthmus.Networks.Firmware.CatalogTest do
  use ExUnit.Case, async: true

  alias Isthmus.Networks.Firmware.Catalog
  alias Isthmus.Networks.Firmware.Offer

  defp fixture(name) do
    __DIR__
    |> Path.join("../../../fixtures/firmware/#{name}")
    |> Path.expand()
    |> File.read!()
    |> Jason.decode!()
  end

  test "parses GitHub excerpts into a snapshot" do
    snap =
      Catalog.snapshot_from_github(%{
        companion: fixture("meshcore_releases.json"),
        island: fixture("island_releases.json"),
        meshtastic: fixture("meshtastic_latest.json"),
        rnode: fixture("rnode_latest.json")
      })

    assert snap.companion.version == "1.17.1"
    refute Enum.any?(snap.companion.assets, &String.contains?(&1.name, "repeater"))
    assert snap.island == nil
    assert snap.meshtastic.version == "2.7.26.54e0d8d"
    assert snap.meshtastic.zip_url =~ "firmware-2.7.26.54e0d8d.zip"
    assert snap.rnode.version == "1.86"
  end

  test "Wio companion matches the USB UF2 from parsed releases" do
    snap =
      Catalog.snapshot_from_github(%{
        companion: fixture("meshcore_releases.json"),
        island: fixture("island_releases.json"),
        meshtastic: fixture("meshtastic_latest.json"),
        rnode: fixture("rnode_latest.json")
      })

    offer = Offer.lookup(:wio_tracker_l1, :companion, snap)
    assert offer.filename =~ "WioTrackerL1_companion_radio_usb"
    refute offer.filename =~ "companion_radio_ble"
    assert Offer.lookup(:wio_tracker_l1, :island, snap) == nil
  end
end
