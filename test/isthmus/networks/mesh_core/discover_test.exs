defmodule Isthmus.Networks.MeshCore.DiscoverTest do
  use ExUnit.Case, async: true

  alias Isthmus.Networks.MeshCore.Discover

  defp fake_ports do
    %{
      "ttyACM0" => %{
        description: "Seeed Wio Tracker L1",
        manufacturer: "Seeed Studio",
        serial_number: "SERIALABC",
        vendor_id: 0x2886,
        product_id: 0x1667
      },
      "ttyACM1" => %{
        description: "Seeed Wio Tracker L1",
        manufacturer: "Seeed Studio",
        serial_number: "SERIALABC",
        vendor_id: 0x2886,
        product_id: 0x1667
      },
      "ttyACM2" => %{
        description: "Heltec",
        manufacturer: "Espressif",
        serial_number: "HELTEC1",
        vendor_id: 0x303A,
        product_id: 0x1001
      }
    }
  end

  test "classifies companion and bridge CLI, assigns sibling packet port" do
    probe = fn
      "/dev/ttyACM0", _ -> :bridge_cli
      "/dev/ttyACM2", _ -> :companion
      _, _ -> :unknown
    end

    roles =
      Discover.scan(
        enumerate: fn -> fake_ports() end,
        probe: probe,
        env: fn _ -> nil end
      )

    assert roles.companion.path == "/dev/ttyACM2"
    assert roles.companion.source == :detected
    assert roles.bridge_cli.path == "/dev/ttyACM0"
    assert roles.bridge_cli.source == :detected
    assert roles.bridge_packet.path == "/dev/ttyACM1"
    assert roles.bridge_packet.source == :detected
  end

  test "env overrides win over detection" do
    probe = fn
      "/dev/ttyACM0", _ -> :bridge_cli
      "/dev/ttyACM2", _ -> :companion
      _, _ -> :unknown
    end

    env = fn
      "ISTHMUS_MESHCORE_PORT" -> "/dev/ttyACM2"
      "ISTHMUS_MESHCORE_BRIDGE_CLI_PORT" -> "/dev/ttyACM0"
      "ISTHMUS_MESHCORE_BRIDGE_PORT" -> "/dev/custom_packet"
      _ -> nil
    end

    roles =
      Discover.scan(
        enumerate: fn -> fake_ports() end,
        probe: probe,
        env: env
      )

    assert roles.companion.path == "/dev/ttyACM2"
    assert roles.companion.source == :env
    assert roles.bridge_cli.path == "/dev/ttyACM0"
    assert roles.bridge_cli.source == :env
    assert roles.bridge_packet.path == "/dev/custom_packet"
    assert roles.bridge_packet.source == :env
  end

  test "resolve_port prefers env then discovered role" do
    name = :"discover_resolve_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Discover,
       name: name,
       enumerate: fn -> fake_ports() end,
       probe: fn
         "/dev/ttyACM2", _ -> :companion
         _, _ -> :unknown
       end,
       env: fn _ -> nil end}
    )

    assert Discover.role(:companion, name) == "/dev/ttyACM2"

    assert Discover.resolve_port(:companion,
             discover: name,
             env: fn
               "ISTHMUS_MESHCORE_PORT" -> "/dev/forced"
               _ -> nil
             end
           ) == "/dev/forced"

    assert Discover.resolve_port(:companion, discover: name, env: fn _ -> nil end) ==
             "/dev/ttyACM2"
  end

  test "falls back to next ACM sibling when serial numbers missing" do
    ports = %{
      "ttyACM0" => %{description: "cli", vendor_id: 0x2886},
      "ttyACM1" => %{description: "pkt", vendor_id: 0x2886}
    }

    roles =
      Discover.scan(
        enumerate: fn -> ports end,
        probe: fn
          "/dev/ttyACM0", _ -> :bridge_cli
          _, _ -> :unknown
        end,
        env: fn _ -> nil end
      )

    assert roles.bridge_packet.path == "/dev/ttyACM1"
  end
end
