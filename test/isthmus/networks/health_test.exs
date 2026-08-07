defmodule Isthmus.Networks.HealthTest do
  use ExUnit.Case, async: true

  alias Isthmus.Networks.Health

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
    assert report.summary =~ "online"
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
end
