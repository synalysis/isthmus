defmodule Isthmus.Networks.Firmware.ImageTest do
  use ExUnit.Case, async: true

  alias Isthmus.FirmwareCatalogFixtures
  alias Isthmus.Networks.Firmware.Board
  alias Isthmus.Networks.Firmware.Image

  test "programmer is esptool for Heltec V3 and UF2 for Wio" do
    assert Board.programmer(:heltec_v3) == :esptool
    assert Board.programmer(:wio_tracker_l1) == :uf2
  end

  test "Meshtastic hyphen names match Heltec V3" do
    names = [
      "firmware-heltec-v3-2.7.26.54e0d8d.bin",
      "firmware-heltec-v3-2.7.26.54e0d8d-update.bin",
      "bleota.bin",
      "littlefs-heltec-v3.bin"
    ]

    assert Image.pick_member(names, :heltec_v3, :meshtastic) ==
             "firmware-heltec-v3-2.7.26.54e0d8d.bin"
  end

  test "UF2 boards prefer the uf2 member" do
    names = [
      "firmware-seeed_wio_tracker_l1-2.7.26.uf2",
      "firmware-seeed_wio_tracker_l1-2.7.26.bin"
    ]

    assert Image.pick_member(names, :wio_tracker_l1, :meshtastic) ==
             "firmware-seeed_wio_tracker_l1-2.7.26.uf2"
  end

  test "extract_zip picks the Heltec app bin from a release zip" do
    zip = Path.join(System.tmp_dir!(), "isthmus-fw-#{System.unique_integer([:positive])}.zip")
    dest = Path.join(System.tmp_dir!(), "isthmus-fw-out-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      File.rm_rf(zip)
      File.rm_rf(dest)
    end)

    FirmwareCatalogFixtures.write_heltec_zip(zip)

    assert {:ok, path} = Image.extract_zip(zip, dest, :heltec_v3, :meshtastic)
    assert Path.basename(path) == "firmware-heltec-v3-2.7.26.54e0d8d.bin"
    assert File.read!(path) == "APP"
  end

  test "flash_offset is 0x10000 for Meshtastic and 0x0 otherwise" do
    assert Image.flash_offset(:meshtastic, "firmware-heltec-v3.bin") == 0x10000
    assert Image.flash_offset(:companion, "Heltec_v3_companion-merged.bin") == 0x0
    assert Image.flash_offset(:rnode, "rnode.bin") == 0x0
  end
end
