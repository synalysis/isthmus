defmodule Isthmus.Networks.UsbAssignmentsTest do
  use Isthmus.DataCase, async: false

  alias Isthmus.Networks.UsbAssignments

  test "assigns and matches by USB serial when present" do
    port = %{
      path: "/dev/ttyUSB0",
      serial_number: "ABC123",
      vendor_id: 0x10C4,
      product_id: 0xEA60
    }

    assert UsbAssignments.role_for(port) == nil
    assert :ok = UsbAssignments.assign(port, :meshtastic)
    assert UsbAssignments.role_for(port) == :meshtastic

    # Dual-CDC siblings share a serial; roles are per path.
    moved = %{port | path: "/dev/ttyUSB1"}
    assert UsbAssignments.role_for(moved) == nil

    assert :ok = UsbAssignments.clear(port)
    assert UsbAssignments.role_for(port) == nil
  end

  test "falls back to path when serial is missing" do
    port = %{path: "/dev/ttyUSB0", serial_number: nil, vendor_id: nil, product_id: nil}

    assert :ok = UsbAssignments.assign(port, "companion")
    assert UsbAssignments.role_for(port) == :companion
    assert UsbAssignments.role_for(%{path: "/dev/ttyUSB1"}) == nil
  end

  test "rejects an unknown role" do
    assert {:error, :invalid_role} =
             UsbAssignments.assign(%{path: "/dev/ttyUSB0"}, :not_a_role)
  end

  test "same USB serial can hold different port roles" do
    a = %{path: "/dev/ttyACM0", serial_number: "WIO1", vendor_id: 0x2886, product_id: 0x1667}
    b = %{path: "/dev/ttyACM1", serial_number: "WIO1", vendor_id: 0x2886, product_id: 0x1667}

    assert :ok = UsbAssignments.assign(a, :bridge_cli)
    assert :ok = UsbAssignments.assign(b, :bridge_packet)
    assert UsbAssignments.role_for(a) == :bridge_cli
    assert UsbAssignments.role_for(b) == :bridge_packet
  end

  test "plan_firmware island uses the port that answers CLI" do
    ports = [
      %{path: "/dev/ttyACM0", serial_number: "WIO1"},
      %{path: "/dev/ttyACM1", serial_number: "WIO1"}
    ]

    probe = fn
      "/dev/ttyACM1", _, :island -> :bridge_cli
      _, _, _ -> :unknown
    end

    roles =
      ports
      |> UsbAssignments.plan_firmware(:island, probe: probe)
      |> Map.new(fn {port, role} -> {port.path, role} end)

    assert roles["/dev/ttyACM1"] == :bridge_cli
    assert roles["/dev/ttyACM0"] == :bridge_packet
  end

  test "plan_firmware island falls back to the lower ttyACM" do
    ports = [
      %{path: "/dev/ttyACM1", serial_number: "WIO1"},
      %{path: "/dev/ttyACM0", serial_number: "WIO1"}
    ]

    roles =
      ports
      |> UsbAssignments.plan_firmware(:island, probe: fn _, _, _ -> :unknown end)
      |> Map.new(fn {port, role} -> {port.path, role} end)

    assert roles["/dev/ttyACM0"] == :bridge_cli
    assert roles["/dev/ttyACM1"] == :bridge_packet
  end

  test "plan_firmware island uses a port that answers as packet traffic" do
    ports = [
      %{path: "/dev/ttyACM0", serial_number: "WIO1"},
      %{path: "/dev/ttyACM1", serial_number: "WIO1"}
    ]

    probe = fn
      "/dev/ttyACM0", _, :island -> :bridge_packet
      _, _, _ -> :unknown
    end

    roles =
      ports
      |> UsbAssignments.plan_firmware(:island, probe: probe)
      |> Map.new(fn {port, role} -> {port.path, role} end)

    assert roles["/dev/ttyACM0"] == :bridge_packet
    assert roles["/dev/ttyACM1"] == :bridge_cli
  end

  test "plan_firmware meshtastic ignores a silent sibling CDC" do
    ports = [
      %{path: "/dev/ttyACM0", serial_number: "WIO1"},
      %{path: "/dev/ttyACM1", serial_number: "WIO1"}
    ]

    probe = fn
      "/dev/ttyACM0", _, :meshtastic -> :meshtastic
      _, _, _ -> :unknown
    end

    roles =
      ports
      |> UsbAssignments.plan_firmware(:meshtastic, probe: probe)
      |> Map.new(fn {port, role} -> {port.path, role} end)

    assert roles["/dev/ttyACM0"] == :meshtastic
    assert roles["/dev/ttyACM1"] == :ignore
  end

  test "plan_firmware companion ignores a silent sibling CDC" do
    ports = [
      %{path: "/dev/ttyACM0", serial_number: "WIO1"},
      %{path: "/dev/ttyACM1", serial_number: "WIO1"}
    ]

    probe = fn
      "/dev/ttyACM1", _, :companion -> :companion
      _, _, _ -> :unknown
    end

    roles =
      ports
      |> UsbAssignments.plan_firmware(:companion, probe: probe)
      |> Map.new(fn {port, role} -> {port.path, role} end)

    assert roles["/dev/ttyACM1"] == :companion
    assert roles["/dev/ttyACM0"] == :ignore
  end

  test "assign_firmware persists island roles from a probe" do
    ports = [
      %{path: "/dev/ttyACM0", serial_number: "WIO1", vendor_id: 0x2886, product_id: 0x1667},
      %{path: "/dev/ttyACM1", serial_number: "WIO1", vendor_id: 0x2886, product_id: 0x1667}
    ]

    probe = fn
      "/dev/ttyACM1", _, :island -> :bridge_cli
      _, _, _ -> :unknown
    end

    assert :ok = UsbAssignments.assign_firmware(ports, :island, probe: probe)

    assert UsbAssignments.role_for(Enum.at(ports, 0)) == :bridge_packet
    assert UsbAssignments.role_for(Enum.at(ports, 1)) == :bridge_cli
  end
end
