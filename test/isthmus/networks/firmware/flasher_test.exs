defmodule Isthmus.Networks.Firmware.FlasherTest do
  use Isthmus.DataCase, async: false

  alias Isthmus.FirmwareCatalogFixtures
  alias Isthmus.Networks.Firmware.Catalog
  alias Isthmus.Networks.Firmware.Flasher
  alias Isthmus.Networks.MeshCore.Discover
  alias Isthmus.Networks.MeshCore.Companion, as: MeshCoreCompanion
  alias Isthmus.Networks.Meshtastic.Companion, as: MeshtasticCompanion

  setup do
    FirmwareCatalogFixtures.reset_flasher()
    previous = FirmwareCatalogFixtures.put_flasher_opts([])
    Phoenix.PubSub.subscribe(Isthmus.PubSub, "firmware:flash")
    on_exit(fn -> FirmwareCatalogFixtures.restore_flasher_opts(previous) end)
    :ok
  end

  test "install holds the path during write and releases after" do
    parent = self()

    FirmwareCatalogFixtures.put_flasher_opts(
      write: fn job ->
        send(parent, {:held, Flasher.held_paths(), job.path})
        :ok
      end,
      refresh: fn ->
        send(parent, :refreshed)
        :ok
      end
    )

    {:ok, job} =
      Flasher.install(%{
        path: "/dev/ttyUSB8",
        device_id: "heltec-1",
        board_id: :heltec_v3,
        kind: :meshtastic,
        catalog: Catalog.fixture_snapshot()
      })

    assert job.programmer == :esptool
    assert_receive {:held, paths, "/dev/ttyUSB8"}
    assert "/dev/ttyUSB8" in paths
    assert_receive {:firmware_flash, %{phase: :done}}
    assert_receive :refreshed
    refute Flasher.held?("/dev/ttyUSB8")
    assert Flasher.status().phase == :done
  end

  test "a second install is busy while a write is running" do
    parent = self()

    FirmwareCatalogFixtures.put_flasher_opts(
      write: fn _job ->
        send(parent, {:wait, self()})
        receive do: (:go -> :ok)
      end
    )

    {:ok, _} =
      Flasher.install(%{
        path: "/dev/ttyUSB8",
        device_id: "heltec-1",
        board_id: :heltec_v3,
        kind: :meshtastic,
        catalog: Catalog.fixture_snapshot()
      })

    assert_receive {:wait, writer}
    on_exit(fn -> send(writer, :go) end)

    assert {:error, :busy} = Flasher.install(%{path: "/dev/ttyUSB7", board_id: :heltec_v3})
    send(writer, :go)
    assert_receive {:firmware_flash, %{phase: :done}}
  end

  test "write errors are published and the hold is cleared" do
    FirmwareCatalogFixtures.put_flasher_opts(write: fn _ -> {:error, :esptool_missing} end)

    {:ok, _} =
      Flasher.install(%{
        path: "/dev/ttyUSB8",
        device_id: "heltec-1",
        board_id: :heltec_v3,
        kind: :meshtastic,
        catalog: Catalog.fixture_snapshot()
      })

    assert_receive {:firmware_flash, %{phase: :error, error: :esptool_missing}}
    refute Flasher.held?("/dev/ttyUSB8")
  end

  test "BLE paths are rejected" do
    assert {:error, :ble_not_supported} =
             Flasher.install(%{
               path: "ble:AA:BB",
               board_id: :heltec_v3,
               kind: :meshtastic,
               catalog: Catalog.fixture_snapshot()
             })
  end

  test "Discover skips a held path and companions will not reconnect it" do
    :ets.insert(:isthmus_firmware_flasher, {:held, ["/dev/ttyUSB8"]})

    assert "/dev/ttyUSB8" in Flasher.held_paths()
    assert "/dev/ttyUSB8" in Discover.claimed_serial_paths()

    probed = :ets.new(:firmware_probed, [:public])

    Discover.scan(
      enumerate: fn ->
        %{
          "ttyUSB8" => %{description: "Heltec"},
          "ttyUSB7" => %{description: "Other"}
        }
      end,
      probe: fn path, _ ->
        :ets.insert(probed, {path, true})
        :unknown
      end,
      env: fn _ -> nil end,
      skip_paths: Discover.claimed_serial_paths()
    )

    refute :ets.member(probed, "/dev/ttyUSB8")
    assert :ets.member(probed, "/dev/ttyUSB7")

    refute MeshtasticCompanion.stay_connected?(%{
             status: :online,
             uart: self(),
             port: "/dev/ttyUSB8",
             fixed_port: true
           })

    refute MeshCoreCompanion.stay_connected?(%{
             status: :online,
             transport: self(),
             port: "/dev/ttyUSB8",
             fixed_port: true
           })
  end
end
