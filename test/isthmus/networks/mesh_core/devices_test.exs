defmodule Isthmus.Networks.MeshCore.DevicesTest do
  use ExUnit.Case, async: true

  alias Isthmus.Networks.MeshCore.Devices

  test "device_id prefers usb vid:pid:serial" do
    assert Devices.device_id(%{
             vendor_id: 0x303A,
             product_id: 0x1001,
             serial_number: "ABC123",
             path: "/dev/ttyACM0"
           }) == "usb:303a:1001:ABC123"
  end

  test "device_id falls back to path" do
    assert Devices.device_id(%{path: "/dev/ttyACM9"}) == "path:/dev/ttyACM9"
  end

  test "inventory groups dual-CDC bridge by serial and attaches roles" do
    ports = [
      %{
        name: "ttyACM0",
        path: "/dev/ttyACM0",
        score: 1,
        reasons: [],
        description: "Bridge",
        manufacturer: "Heltec",
        serial_number: "BR1",
        vendor_id: 0x303A,
        product_id: 0x1001
      },
      %{
        name: "ttyACM1",
        path: "/dev/ttyACM1",
        score: 1,
        reasons: [],
        description: "Bridge",
        manufacturer: "Heltec",
        serial_number: "BR1",
        vendor_id: 0x303A,
        product_id: 0x1001
      },
      %{
        name: "ttyACM2",
        path: "/dev/ttyACM2",
        score: 1,
        reasons: [],
        description: "Companion",
        manufacturer: "Seeed",
        serial_number: "CP1",
        vendor_id: 0x2886,
        product_id: 0x802F
      }
    ]

    roles = %{
      companion: %{path: "/dev/ttyACM2", detail: %{}},
      bridge_cli: %{path: "/dev/ttyACM0", detail: %{}},
      bridge_packet: %{path: "/dev/ttyACM1", detail: %{}}
    }

    devices =
      Devices.inventory(
        ports: ports,
        roles: roles,
        companion: %{status: :online, port: "/dev/ttyACM2", self_name: "Gate"},
        bridge_cli: %{status: :online, port: "/dev/ttyACM0"},
        bridge_link: %{status: :online, port: "/dev/ttyACM1", frames_in: 3}
      )

    assert length(devices) == 2

    companion = Enum.find(devices, & &1.companion?)
    bridge = Enum.find(devices, & &1.bridge_cli?)

    assert companion.id == "usb:2886:802f:CP1"
    assert companion.kind == :companion
    assert companion.label == "Gate"
    assert companion.active_companion?
    assert length(companion.ports) == 1

    assert bridge.id == "usb:303a:1001:BR1"
    assert bridge.kind == :bridge_repeater
    assert bridge.bridge_packet?
    assert bridge.active_bridge_cli?
    assert bridge.active_bridge_link?
    assert Enum.map(bridge.ports, & &1.role) == [:bridge_cli, :bridge_packet]
    assert bridge.bridge_link_health[:frames_in] == 3
  end

  test "inventory lists each MeshCore companion as its own device" do
    ports = [
      %{
        name: "ttyACM2",
        path: "/dev/ttyACM2",
        score: 1,
        reasons: [],
        description: "Companion A",
        manufacturer: "Seeed",
        serial_number: "CP1",
        vendor_id: 0x2886,
        product_id: 0x802F
      },
      %{
        name: "ttyACM3",
        path: "/dev/ttyACM3",
        score: 1,
        reasons: [],
        description: "Companion B",
        manufacturer: "Seeed",
        serial_number: "CP2",
        vendor_id: 0x2886,
        product_id: 0x802F
      }
    ]

    roles = %{
      companion: %{path: "/dev/ttyACM2", detail: %{}},
      companion_ports: [
        %{path: "/dev/ttyACM2", detail: %{}},
        %{path: "/dev/ttyACM3", detail: %{}}
      ]
    }

    devices =
      Devices.inventory(
        ports: ports,
        roles: roles,
        companions: [
          %{status: :online, port: "/dev/ttyACM2", self_name: "Gate A", self_ref: "aa"},
          %{status: :online, port: "/dev/ttyACM3", self_name: "Gate B", self_ref: "bb"}
        ],
        bridge_cli: %{},
        bridge_link: %{}
      )

    assert length(devices) == 2
    assert Enum.all?(devices, & &1.companion?)
    assert Enum.all?(devices, & &1.active_companion?)
    names = Enum.map(devices, & &1.label) |> Enum.sort()
    assert names == ["Gate A", "Gate B"]
  end

  test "inventory ignores a Meshtastic discover role" do
    ports = [
      %{
        name: "ttyUSB0",
        path: "/dev/ttyUSB0",
        score: 1,
        reasons: [],
        description: "Meshtastic",
        manufacturer: "Silicon Labs",
        serial_number: "MT1",
        vendor_id: 0x10C4,
        product_id: 0xEA60
      }
    ]

    devices =
      Devices.inventory(
        ports: ports,
        roles: %{meshtastic: %{path: "/dev/ttyUSB0", detail: %{}}},
        companion: %{},
        bridge_cli: %{},
        bridge_link: %{}
      )

    assert devices == []
  end

  test "inventory ignores every Meshtastic companion path" do
    ports = [
      %{
        name: "ttyUSB0",
        path: "/dev/ttyUSB0",
        score: 1,
        reasons: [],
        description: "Meshtastic A",
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
        serial_number: "MT2",
        vendor_id: 0x10C4,
        product_id: 0xEA60
      }
    ]

    devices =
      Devices.inventory(
        ports: ports,
        roles: %{
          meshtastic: %{path: "/dev/ttyUSB0", detail: %{}},
          meshtastic_ports: [
            %{path: "/dev/ttyUSB0"},
            %{path: "/dev/ttyUSB1"}
          ]
        },
        companion: %{},
        bridge_cli: %{},
        bridge_link: %{}
      )

    assert devices == []
  end

  test "inventory ignores a detected RNode" do
    ports = [
      %{
        name: "ttyACM3",
        path: "/dev/ttyACM3",
        score: 1,
        reasons: [],
        description: "RNode",
        manufacturer: "Espressif",
        serial_number: "RN1",
        vendor_id: 0x303A,
        product_id: 0x1001
      }
    ]

    devices =
      Devices.inventory(
        ports: ports,
        roles: %{
          rnode: %{path: "/dev/ttyACM3", detail: %{}},
          rnode_ports: [%{path: "/dev/ttyACM3"}]
        },
        companion: %{},
        bridge_cli: %{},
        bridge_link: %{}
      )

    assert devices == []
  end

  test "inventory includes BLE companions from health" do
    devices =
      Devices.inventory(
        ports: [],
        roles: %{},
        companions: [
          %{
            status: :online,
            port: "ble:AA:BB:CC:DD:EE:FF",
            ble_address: "AA:BB:CC:DD:EE:FF",
            self_name: "MeshCore-T1000",
            self_ref: "aabb"
          }
        ],
        bridge_cli: %{},
        bridge_link: %{}
      )

    assert [device] = devices
    assert device.ble?
    assert device.kind == :companion
    assert device.id == "ble:AA:BB:CC:DD:EE:FF"
    assert device.label == "MeshCore-T1000"
    assert device.active_companion?
  end
end
