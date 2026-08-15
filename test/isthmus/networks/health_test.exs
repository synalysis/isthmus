defmodule Isthmus.Networks.HealthTest do
  use ExUnit.Case, async: true

  alias Isthmus.Networks.Health

  test "diagnoses MeshCore BLE timeout" do
    report =
      Health.normalize(:meshcore, %{
        status: :error,
        port: "ble:F0:FC:59:52:BD:27",
        transport: :ble,
        last_error: ":timeout"
      })

    assert report.severity == :error
    assert report.issue =~ "timed out"
    assert report.fix =~ "Reconnect"
  end

  test "diagnoses MeshCore BLE InProgress" do
    report =
      Health.normalize(:meshcore, %{
        status: :error,
        port: "ble:F0:FC:59:52:BD:27",
        transport: :ble,
        last_error: "[org.bluez.Error.InProgress] Operation already in progress"
      })

    assert report.severity == :error
    assert report.issue =~ "busy"
    assert report.fix =~ "Reconnect"
  end

  test "diagnoses MeshCore eacces with dialout fix" do
    report =
      Health.normalize(:meshcore, %{
        status: :error,
        port: "/dev/ttyUSB0",
        transport: :usb,
        last_error: ":eacces",
        detail: "Companion USB/BLE transport"
      })

    assert report.severity == :error
    assert report.issue =~ "Permission denied"
    assert report.fix =~ "dialout"
    assert report.fix =~ "sg dialout"
  end

  test "online meshcore is ok" do
    report =
      Health.normalize(:meshcore, %{
        status: :online,
        port: "/dev/ttyUSB0",
        transport: :usb
      })

    assert report.severity == :ok
    assert is_nil(report.issue)
    assert report.summary =~ "Companion radio connected"
    assert {"Companion", "/dev/ttyUSB0"} in report.meta
  end

  test "island tunnel radio online is ok even without a companion" do
    report =
      Health.normalize(:meshcore, %{
        status: :disabled,
        last_error: "no port configured",
        detail: "Companion USB/BLE transport",
        bridge: %{status: :online, port: "/dev/ttyACM1", frames_in: 12, frames_out: 3},
        bridge_cli: %{status: :online, port: "/dev/ttyACM0"}
      })

    assert report.status == :online
    assert report.severity == :ok
    assert is_nil(report.issue)
    assert report.summary =~ "Island tunnel radio connected"
    refute report.summary =~ "disabled"
    refute report.summary =~ "Companion"
    assert {"Island tunnel", "/dev/ttyACM1"} in report.meta
    assert {"Island CLI", "/dev/ttyACM0"} in report.meta
  end

  test "no MeshCore radios is not companion-centric" do
    report =
      Health.normalize(:meshcore, %{
        status: :disabled,
        last_error: "no port configured",
        bridge: %{status: :disabled},
        bridge_cli: %{status: :disabled}
      })

    assert report.status == :disabled
    assert report.severity == :info
    assert report.summary == "No MeshCore radios detected"
    refute report.summary =~ "Companion disabled"
    assert report.fix =~ "island tunnel"
  end

  test "nostr with zero online relays warns" do
    report =
      Health.normalize(:nostr, %{
        status: :running,
        online: 0,
        relays_enabled: 3,
        events_seen: 0
      })

    assert report.severity == :error
    assert report.issue =~ "No relays are online"
  end

  test "reticulum live is ok (not degraded)" do
    report =
      Health.normalize(:reticulum, %{
        status: :live,
        live: true,
        configdir: "/tmp/rns",
        meta: %{"rns_version" => "1.4.2"}
      })

    assert report.severity == :ok
    assert is_nil(report.issue)
    assert report.summary =~ "live"
  end

  test "reticulum online but not live explains why" do
    report =
      Health.normalize(:reticulum, %{
        status: :online,
        live: false,
        last_error: nil
      })

    assert report.severity == :warn
    assert report.issue =~ "Waiting for RNS/LXMF hello"
    assert report.fix =~ "pip install"
  end

  test "online meshtastic includes radio clock in meta" do
    report =
      Health.normalize(:meshtastic, %{
        status: :online,
        port: "/dev/ttyUSB0",
        node_id: "aabbccdd",
        region_label: "US",
        modem_preset_label: "Long Fast",
        device_time_now: 1_700_000_000,
        sent: 3,
        received: 9
      })

    assert report.severity == :ok
    assert {"Clock", "2023-11-14 22:13:20 UTC"} in report.meta
    assert {"Node", "!aabbccdd"} in report.meta
  end

  test "disabled meshtastic companion explains auto-detect" do
    report =
      Health.normalize(:meshtastic, %{
        status: :disabled,
        last_error: "no companion detected (set ISTHMUS_MESHTASTIC_PORT to override)"
      })

    assert report.severity == :info
    assert report.summary =~ "offline"
    assert report.fix =~ "Rescan" or report.fix =~ "ISTHMUS_MESHTASTIC_PORT"
  end
end
