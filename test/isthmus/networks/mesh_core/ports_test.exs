defmodule Isthmus.Networks.MeshCore.PortsTest do
  use ExUnit.Case, async: true

  alias Isthmus.Networks.MeshCore.Ports

  test "suggests Silicon Labs USB-UART over bare ttyS" do
    enumerate = fn ->
      %{
        "ttyS0" => %{},
        "ttyUSB0" => %{
          description: "CP2102 USB to UART Bridge Controller",
          manufacturer: "Silicon Labs",
          vendor_id: 0x10C4,
          product_id: 0xEA60
        },
        "ttyACM0" => %{
          description: "nRF52 USB CDC",
          manufacturer: "Nordic Semiconductor",
          vendor_id: 0x1915,
          product_id: 0x520F
        }
      }
    end

    ports = Ports.list(enumerate: enumerate)
    paths = Enum.map(ports, & &1.path)
    refute "/dev/ttyS0" in paths
    assert "/dev/ttyUSB0" in paths
    assert "/dev/ttyACM0" in paths

    # Both are strong; ACM Nordic / USB Silabs — either is fine; scores > 0
    assert Ports.suggest(enumerate: enumerate) in ["/dev/ttyUSB0", "/dev/ttyACM0"]
  end

  test "prefers configured env when present" do
    enumerate = fn ->
      %{
        "ttyUSB0" => %{vendor_id: 0x10C4, product_id: 0xEA60, manufacturer: "Silicon Labs"},
        "ttyACM0" => %{vendor_id: 0x1915, product_id: 1, manufacturer: "Nordic Semiconductor"}
      }
    end

    assert Ports.suggest(enumerate: enumerate, configured: "/dev/ttyUSB0") == "/dev/ttyUSB0"
  end

  test "format_report includes suggestion line" do
    enumerate = fn ->
      %{"ttyUSB0" => %{vendor_id: 0x10C4, product_id: 0xEA60, manufacturer: "Silicon Labs"}}
    end

    report = Ports.format_report(enumerate: enumerate, configured: nil) |> Enum.join("\n")
    assert report =~ "Suggested ISTHMUS_MESHCORE_PORT=/dev/ttyUSB0"
  end
end
