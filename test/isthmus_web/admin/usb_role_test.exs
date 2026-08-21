defmodule IsthmusWeb.Admin.UsbRoleTest do
  use Isthmus.DataCase, async: false

  alias Isthmus.Networks.UsbAssignments
  alias IsthmusWeb.Admin.UsbRole

  test "firmware_kind prefers a companion assignment over a live Meshtastic radio" do
    port = %{
      path: "/dev/ttyUSB9",
      serial_number: "WIO1",
      vendor_id: 0x2886,
      product_id: 0x1667
    }

    assert :ok = UsbAssignments.assign(port, :companion)

    device = %{
      id: "usb:2886:1667:WIO1",
      path: port.path,
      kind: :meshtastic,
      usb_role: :meshtastic,
      serial_number: port.serial_number,
      vendor_id: port.vendor_id,
      product_id: port.product_id,
      ports: [%{path: port.path, role: :meshtastic}]
    }

    assert UsbRole.firmware_kind(device) == :companion
  end

  test "firmware_kind stays Meshtastic when that is the assignment" do
    port = %{path: "/dev/ttyUSB9", serial_number: "WIO1"}
    assert :ok = UsbAssignments.assign(port, :meshtastic)

    device = %{
      path: port.path,
      kind: :meshtastic,
      serial_number: "WIO1",
      usb_role: :meshtastic
    }

    assert UsbRole.firmware_kind(device) == :meshtastic
  end
end
