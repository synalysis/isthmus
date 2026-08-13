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
  end
end
