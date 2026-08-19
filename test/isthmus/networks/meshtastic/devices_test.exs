defmodule Isthmus.Networks.Meshtastic.DevicesTest do
  use ExUnit.Case, async: true

  alias Isthmus.Networks.Meshtastic.Devices

  test "inventory lists each Meshtastic companion as its own device" do
    ports = [
      %{
        name: "ttyUSB0",
        path: "/dev/ttyUSB0",
        score: 1,
        reasons: [],
        description: "Meshtastic A",
        manufacturer: "Silicon Labs",
        serial_number: "MT1",
        vendor_id: 0x10C4,
        product_id: 0xEA60
      },
      %{
        name: "ttyUSB1",
        path: "/dev/ttyUSB1",
        score: 1,
        reasons: [],
        description: "Meshtastic B",
        manufacturer: "Silicon Labs",
        serial_number: "MT2",
        vendor_id: 0x10C4,
        product_id: 0xEA60
      }
    ]

    devices =
      Devices.inventory(
        ports: ports,
        roles: %{
          meshtastic: %{path: "/dev/ttyUSB0", source: :detected, detail: %{}},
          meshtastic_ports: [
            %{path: "/dev/ttyUSB0", source: :detected, detail: %{}},
            %{path: "/dev/ttyUSB1", source: :detected, detail: %{}}
          ]
        },
        healths: [
          %{status: :online, port: "/dev/ttyUSB0", node_id: "aabbccdd", primary?: true},
          %{status: :online, port: "/dev/ttyUSB1", node_id: "11223344", primary?: false}
        ]
      )

    assert length(devices) == 2

    primary = Enum.find(devices, & &1.primary?)
    extra = Enum.find(devices, &(not &1.primary?))

    assert primary.path == "/dev/ttyUSB0"
    assert primary.kind == :meshtastic
    assert primary.label == "!aabbccdd"
    assert primary.active?
    assert extra.path == "/dev/ttyUSB1"
    assert extra.label == "!11223344"
    refute extra.primary?
    refute extra.ble?
  end

  test "inventory lists an unidentified CP2102 UART on Meshtastic, not as a live companion" do
    ports = [
      %{
        name: "ttyUSB0",
        path: "/dev/ttyUSB0",
        score: 1,
        reasons: [],
        description: "CP2102 USB to UART Bridge Controller",
        manufacturer: "Silicon Labs",
        serial_number: "0001",
        vendor_id: 0x10C4,
        product_id: 0xEA60
      }
    ]

    devices =
      Devices.inventory(
        ports: ports,
        roles: %{
          meshtastic: nil,
          meshtastic_ports: [],
          probe_errors: %{"/dev/ttyUSB0" => :eacces}
        },
        healths: []
      )

    assert [device] = devices
    assert device.path == "/dev/ttyUSB0"
    assert device.kind == :unknown
    assert device.probe_error == :eacces
    refute device.active?
    assert device.label =~ "CP2102"
  end

  test "inventory skips a UART already claimed as MeshCore companion" do
    ports = [
      %{
        name: "ttyUSB0",
        path: "/dev/ttyUSB0",
        score: 1,
        reasons: [],
        description: "CP2102 USB to UART Bridge Controller",
        vendor_id: 0x10C4,
        product_id: 0xEA60
      }
    ]

    devices =
      Devices.inventory(
        ports: ports,
        roles: %{
          companion: %{path: "/dev/ttyUSB0", source: :detected, detail: %{}},
          meshtastic: nil,
          meshtastic_ports: []
        },
        healths: []
      )

    assert devices == []
  end

  test "inventory includes Bluetooth companions from health" do
    devices =
      Devices.inventory(
        ports: [],
        roles: %{meshtastic: nil, meshtastic_ports: []},
        healths: [
          %{
            status: :online,
            port: "ble:11:22:33:44:55:66",
            ble_address: "11:22:33:44:55:66",
            name: "Meshtastic_Andreas",
            node_id: nil
          }
        ]
      )

    assert [device] = devices
    assert device.ble?
    assert device.ble_address == "11:22:33:44:55:66"
    assert device.label == "Meshtastic_Andreas"
    assert device.path == "ble:11:22:33:44:55:66"
  end
end
