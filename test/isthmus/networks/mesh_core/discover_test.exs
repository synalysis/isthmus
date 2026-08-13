defmodule Isthmus.Networks.MeshCore.DiscoverTest do
  use ExUnit.Case, async: true

  alias Isthmus.Networks.MeshCore.Discover
  alias Isthmus.Networks.Meshtastic.Protobuf
  alias Isthmus.Networks.Meshtastic.Protocol, as: MeshtasticProtocol

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

  test "classifies a Meshtastic companion on a remaining USB port" do
    probe = fn
      "/dev/ttyACM0", _ -> :bridge_cli
      "/dev/ttyACM2", _ -> :companion
      "/dev/ttyUSB0", _ -> :meshtastic
      _, _ -> :unknown
    end

    ports =
      Map.put(fake_ports(), "ttyUSB0", %{
        description: "Meshtastic",
        manufacturer: "Silicon Labs",
        serial_number: "MT1",
        vendor_id: 0x10C4,
        product_id: 0xEA60
      })

    roles =
      Discover.scan(
        enumerate: fn -> ports end,
        probe: probe,
        env: fn _ -> nil end
      )

    assert roles.meshtastic.path == "/dev/ttyUSB0"
    assert roles.meshtastic.source == :detected
    assert Enum.map(roles.meshtastic_ports, & &1.path) == ["/dev/ttyUSB0"]
    assert roles.companion.path == "/dev/ttyACM2"
    assert roles.bridge_packet.path == "/dev/ttyACM1"
  end

  test "classifies every Meshtastic companion, not just the first" do
    probe = fn
      "/dev/ttyUSB0", _ -> :meshtastic
      "/dev/ttyUSB1", _ -> :meshtastic
      _, _ -> :unknown
    end

    ports = %{
      "ttyUSB0" => %{
        description: "Meshtastic A",
        manufacturer: "Silicon Labs",
        serial_number: "MT1",
        vendor_id: 0x10C4,
        product_id: 0xEA60
      },
      "ttyUSB1" => %{
        description: "Meshtastic B",
        manufacturer: "Silicon Labs",
        serial_number: "MT2",
        vendor_id: 0x10C4,
        product_id: 0xEA60
      }
    }

    roles =
      Discover.scan(
        enumerate: fn -> ports end,
        probe: probe,
        env: fn _ -> nil end
      )

    assert roles.meshtastic.path == "/dev/ttyUSB0"
    assert Enum.map(roles.meshtastic_ports, & &1.path) == ["/dev/ttyUSB0", "/dev/ttyUSB1"]
  end

  test "keeps every MeshCore companion port" do
    probe = fn
      "/dev/ttyACM0", _ -> :companion
      "/dev/ttyACM2", _ -> :companion
      _, _ -> :unknown
    end

    roles =
      Discover.scan(
        enumerate: fn -> fake_ports() end,
        probe: probe,
        env: fn _ -> nil end
      )

    paths = Enum.map(roles.companion_ports, & &1.path)
    assert "/dev/ttyACM0" in paths
    assert "/dev/ttyACM2" in paths
    assert roles.companion.path in paths
    assert length(paths) == 2
  end

  test "env ISTHMUS_MESHTASTIC_PORT is not stolen as a MeshCore packet sibling" do
    probe = fn
      "/dev/ttyACM0", _ -> :bridge_cli
      _, _ -> :unknown
    end

    env = fn
      "ISTHMUS_MESHTASTIC_PORT" -> "/dev/ttyACM1"
      _ -> nil
    end

    roles =
      Discover.scan(
        enumerate: fn -> fake_ports() end,
        probe: probe,
        env: env
      )

    assert roles.meshtastic.path == "/dev/ttyACM1"
    assert roles.meshtastic.source == :env
    refute Map.has_key?(roles, :bridge_packet)
  end

  test "resolve_port :meshtastic prefers env then discovered role" do
    name = :"discover_mt_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Discover,
       name: name,
       enumerate: fn -> fake_ports() end,
       probe: fn
         "/dev/ttyACM2", _ -> :meshtastic
         _, _ -> :unknown
       end,
       env: fn _ -> nil end}
    )

    assert Discover.role(:meshtastic, name) == "/dev/ttyACM2"

    assert Discover.resolve_port(:meshtastic,
             discover: name,
             env: fn
               "ISTHMUS_MESHTASTIC_PORT" -> "/dev/forced_mt"
               _ -> nil
             end
           ) == "/dev/forced_mt"

    assert Discover.resolve_ports(:meshtastic, discover: name, env: fn _ -> nil end) ==
             ["/dev/ttyACM2"]
  end

  test "resolve_ports :meshtastic lists env pin then every detected radio" do
    name = :"discover_mt_ports_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Discover,
       name: name,
       enumerate: fn ->
         %{
           "ttyUSB0" => %{description: "Meshtastic A"},
           "ttyUSB1" => %{description: "Meshtastic B"}
         }
       end,
       probe: fn
         "/dev/ttyUSB0", _ -> :meshtastic
         "/dev/ttyUSB1", _ -> :meshtastic
         _, _ -> :unknown
       end,
       env: fn _ -> nil end}
    )

    assert Discover.resolve_ports(:meshtastic,
             discover: name,
             env: fn
               "ISTHMUS_MESHTASTIC_PORT" -> "/dev/forced_mt"
               _ -> nil
             end
           ) == ["/dev/forced_mt", "/dev/ttyUSB0", "/dev/ttyUSB1"]
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

  test "classifies a USB RNode and does not steal it as a packet sibling" do
    probe = fn
      "/dev/ttyACM0", _ -> :bridge_cli
      "/dev/ttyACM1", _ -> :rnode
      "/dev/ttyACM2", _ -> :companion
      _, _ -> :unknown
    end

    roles =
      Discover.scan(
        enumerate: fn -> fake_ports() end,
        probe: probe,
        env: fn _ -> nil end
      )

    assert roles.rnode.path == "/dev/ttyACM1"
    assert Enum.map(roles.rnode_ports, & &1.path) == ["/dev/ttyACM1"]
    refute Map.has_key?(roles, :bridge_packet)
    assert roles.companion.path == "/dev/ttyACM2"
    assert roles.bridge_cli.path == "/dev/ttyACM0"
  end

  test "keep_still_attached restores a Meshtastic radio that is still plugged in" do
    previous = %{
      meshtastic: %{path: "/dev/ttyUSB0", source: :detected, detail: nil},
      meshtastic_ports: [%{path: "/dev/ttyUSB0", source: :detected, detail: nil}]
    }

    restored =
      Discover.keep_still_attached(%{meshtastic_ports: []}, previous, ["/dev/ttyUSB0"])

    assert restored.meshtastic.path == "/dev/ttyUSB0"
    assert Enum.map(restored.meshtastic_ports, & &1.path) == ["/dev/ttyUSB0"]
  end

  test "keep_still_attached drops radios that are no longer attached" do
    previous = %{
      meshtastic: %{path: "/dev/ttyUSB0", source: :detected, detail: nil},
      meshtastic_ports: [%{path: "/dev/ttyUSB0", source: :detected, detail: nil}]
    }

    restored = Discover.keep_still_attached(%{meshtastic_ports: []}, previous, [])

    refute Map.has_key?(restored, :meshtastic)
    assert restored.meshtastic_ports == []
  end

  test "keep_still_attached restores a MeshCore companion that is still plugged in" do
    previous = %{
      companion: %{path: "/dev/ttyACM2", source: :detected, detail: nil},
      companion_ports: [%{path: "/dev/ttyACM2", source: :detected, detail: nil}]
    }

    restored =
      Discover.keep_still_attached(%{companion_ports: []}, previous, ["/dev/ttyACM2"])

    assert restored.companion.path == "/dev/ttyACM2"
    assert Enum.map(restored.companion_ports, & &1.path) == ["/dev/ttyACM2"]
  end

  test "keep_still_attached does not restore MeshCore when the same port is now Meshtastic" do
    previous = %{
      companion: %{path: "/dev/ttyUSB0", source: :detected, detail: nil},
      companion_ports: [%{path: "/dev/ttyUSB0", source: :detected, detail: nil}]
    }

    current = %{
      meshtastic: %{path: "/dev/ttyUSB0", source: :detected, detail: nil},
      meshtastic_ports: [%{path: "/dev/ttyUSB0", source: :detected, detail: nil}]
    }

    restored = Discover.keep_still_attached(current, previous, ["/dev/ttyUSB0"])

    refute Map.has_key?(restored, :companion)
    assert restored.meshtastic.path == "/dev/ttyUSB0"
    refute Enum.any?(restored[:companion_ports] || [], &(&1.path == "/dev/ttyUSB0"))
    assert Enum.map(restored.meshtastic_ports, & &1.path) == ["/dev/ttyUSB0"]
  end

  test "classify_probe_buffer ignores ESP32 boot noise that looks like DEVICE_INFO" do
    boot = "rst:0x1 (POWERON_RESET),boot:0x13\r\n>" <> <<1::little-16, 13>>
    assert Discover.classify_probe_buffer(boot) == :unknown
  end

  test "classify_probe_buffer treats any complete Meshtastic serial frame as Meshtastic" do
    metadata = MeshtasticProtocol.encode_frame(Protobuf.encode_message_field(13, <<>>))
    log_record = MeshtasticProtocol.encode_frame(Protobuf.encode_bytes_field(6, "boot"))

    assert Discover.classify_probe_buffer(metadata) == :meshtastic
    assert Discover.classify_probe_buffer(log_record) == :meshtastic
  end

  test "classify_probe_buffer prefers Meshtastic frames over a spurious companion decode" do
    boot = ">" <> <<1::little-16, 13>>
    inner = Protobuf.encode_varint_field(1, 0xDEADBEEF)
    payload = Protobuf.encode_message_field(3, inner)
    meshtastic = MeshtasticProtocol.encode_frame(payload)

    assert Discover.classify_probe_buffer(boot <> meshtastic) == :meshtastic
  end

  test "classify_probe_buffer accepts a real MeshCore DEVICE_INFO frame" do
    rest = <<3, 100, 8>> <> :binary.copy(<<0>>, 77)
    frame = <<13, rest::binary>>
    buffer = <<">", byte_size(frame)::little-16, frame::binary>>
    assert Discover.classify_probe_buffer(buffer) == :companion
  end

  test "cli_probe_reply? requires the MeshCore -> prompt, not a bare firmware token" do
    refute Discover.cli_probe_reply?("Meshtastic firmware 2.6.0")
    refute Discover.cli_probe_reply?("v1.0 build:abc")
    assert Discover.cli_probe_reply?("-> v1.8.1 firmware")
    assert Discover.cli_probe_reply?("-> ver 1.8")
  end

  test "refresh keeps a Meshtastic radio when a later probe cannot reopen the port" do
    {:ok, agent} = start_supervised({Agent, fn -> :meshtastic end})
    name = :"discover_keep_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Discover,
       name: name,
       enumerate: fn -> %{"ttyUSB0" => %{description: "Meshtastic"}} end,
       probe: fn
         "/dev/ttyUSB0", _ -> Agent.get(agent, & &1)
         _, _ -> :unknown
       end,
       env: fn _ -> nil end}
    )

    assert Discover.role(:meshtastic, name) == "/dev/ttyUSB0"

    :ok = Agent.update(agent, fn _ -> :unknown end)
    assert {:ok, roles} = Discover.refresh(name)
    assert roles.meshtastic.path == "/dev/ttyUSB0"
    assert Enum.map(roles.meshtastic_ports, & &1.path) == ["/dev/ttyUSB0"]
  end
end
