defmodule IsthmusWeb.Admin.CopyTest do
  use ExUnit.Case, async: true

  alias IsthmusWeb.Admin.Copy

  test "status_plain never exposes disabled" do
    assert Copy.status_plain(:disabled) == "Offline"
    assert Copy.status_plain(:online) == "Connected"
    assert Copy.status_plain(:connecting) == "Connecting"
  end

  test "device_purpose for unknown radios" do
    assert {"Radio not identified", _} = Copy.device_purpose(%{kind: :unknown})
    assert {"Companion radio", _} = Copy.device_purpose(%{kind: :companion})
    assert {"Companion radio", blurb} = Copy.device_purpose(%{kind: :companion, ble?: true})
    assert blurb =~ "Bluetooth"
    assert {"Companion radio", mt} = Copy.device_purpose(%{kind: :meshtastic, ble?: true})
    assert mt =~ "Bluetooth"
    assert {"Island tunnel radio", _} = Copy.device_purpose(%{kind: :bridge_repeater})
  end

  test "device_status surfaces companion error" do
    assert {:error, "Error"} =
             Copy.device_status(%{
               kind: :companion,
               ble?: true,
               active_companion?: false,
               companion_health: %{status: :error, last_error: "InProgress"}
             })
  end

  test "bootloader USB is called out separately" do
    boot = %{kind: :unknown, description: "T1000-E-BOOT", label: "T1000-E-BOOT"}
    assert Copy.bootloader_usb?(boot)
    assert {"USB bootloader", _} = Copy.device_purpose(boot)
    assert {:unknown, "Bootloader"} = Copy.device_status(boot)
  end

  test "role_plain avoids Unassigned" do
    assert Copy.role_plain(:unassigned) == "Not identified yet"
    assert Copy.role_plain(:bridge_packet) == "Mesh traffic port"
  end

  test "group_kind_label maps bridge to group" do
    assert Copy.group_kind_label("bridge") == "group"
  end
end
