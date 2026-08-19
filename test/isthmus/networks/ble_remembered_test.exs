defmodule Isthmus.Networks.BLERememberedTest do
  use Isthmus.DataCase, async: false

  alias Isthmus.Networks.BLERemembered

  setup do
    for network <- [:meshtastic, :meshcore] do
      for %{"address" => addr} <- BLERemembered.list(network) do
        BLERemembered.forget(network, addr)
      end
    end

    :ok
  end

  test "remembers and forgets a Meshtastic Bluetooth address" do
    assert BLERemembered.list(:meshtastic) == []

    assert :ok = BLERemembered.remember(:meshtastic, "aa:bb:cc:dd:ee:ff", name: "MeshPocket")

    assert BLERemembered.list(:meshtastic) == [
             %{"address" => "AA:BB:CC:DD:EE:FF", "name" => "MeshPocket"}
           ]

    assert :ok = BLERemembered.forget(:meshtastic, "ble:AA:BB:CC:DD:EE:FF")
    assert BLERemembered.list(:meshtastic) == []
  end

  test "remember is idempotent and keeps an existing name" do
    assert :ok = BLERemembered.remember(:meshcore, "11:22:33:44:55:66", name: "T1000")
    assert :ok = BLERemembered.remember(:meshcore, "11:22:33:44:55:66")

    assert %{"address" => "11:22:33:44:55:66", "name" => "T1000"} in BLERemembered.list(:meshcore)
  end

  test "remember_healths snapshots online BLE companions" do
    BLERemembered.remember_healths(:meshtastic, [
      %{
        status: :online,
        port: "ble:de:ad:be:ef:00:01",
        ble_address: "de:ad:be:ef:00:01",
        name: "Trail"
      },
      %{status: :disabled, ble_address: "00:00:00:00:00:00"}
    ])

    assert BLERemembered.list(:meshtastic) == [
             %{"address" => "DE:AD:BE:EF:00:01", "name" => "Trail"}
           ]
  end
end
