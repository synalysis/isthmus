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

  test "silent dual-CDC Wio is not assumed to be a MeshCore island" do
    roles =
      Discover.scan(
        enumerate: fn -> fake_ports() end,
        probe: fn _, _ -> :unknown end,
        env: fn _ -> nil end
      )

    refute Map.has_key?(roles, :bridge_cli)
    refute Map.has_key?(roles, :bridge_packet)
    refute Map.has_key?(roles, :meshtastic)
  end

  test "silent dual-CDC heuristic does not steal a Meshtastic Wio port" do
    roles =
      Discover.scan(
        enumerate: fn -> fake_ports() end,
        probe: fn
          "/dev/ttyACM0", _ -> :meshtastic
          "/dev/ttyACM1", _ -> :unknown
          _, _ -> :unknown
        end,
        env: fn _ -> nil end
      )

    assert roles.meshtastic.path == "/dev/ttyACM0"
    refute Map.has_key?(roles, :bridge_cli)
  end

  test "bootloader CDC is not treated as an island bridge" do
    ports = %{
      "ttyACM0" => %{
        description: "T1000-E-BOOT",
        manufacturer: "Adafruit",
        serial_number: "BOOT1",
        vendor_id: 0x239A,
        product_id: 0x8029
      },
      "ttyACM1" => %{
        description: "T1000-E-BOOT",
        manufacturer: "Adafruit",
        serial_number: "BOOT1",
        vendor_id: 0x239A,
        product_id: 0x8029
      }
    }

    roles =
      Discover.scan(
        enumerate: fn -> ports end,
        probe: fn _, _ -> :unknown end,
        env: fn _ -> nil end
      )

    refute Map.has_key?(roles, :bridge_cli)
    refute Map.has_key?(roles, :bridge_packet)
  end

  test "Wio Tracker L1 USB identity is shared by Meshtastic and MeshCore firmware" do
    wio = %{
      description: "Seeed Wio Tracker L1",
      manufacturer: "Seeed Studio",
      vendor_id: 0x2886,
      product_id: 0x1667
    }

    assert Discover.ambiguous_nrf_board?(wio)

    refute Discover.ambiguous_nrf_board?(%{
             description: "Heltec",
             vendor_id: 0x303A,
             product_id: 0x1001
           })

    refute Discover.ambiguous_nrf_board?(%{
             description: "T1000-E-BOOT",
             vendor_id: 0x239A,
             product_id: 0x8029
           })

    assert Discover.ambiguous_nrf_board?(%{
             description: "T1000-E",
             vendor_id: 0x2886,
             product_id: 0x0057
           })

    assert Discover.ambiguous_nrf_board?(%{
             description: "T1000-E",
             vendor_id: 0x239A,
             product_id: 0x8029
           })

    assert Discover.serial_firmware_ambiguous?(%{
             description: "CP2102 USB to UART Bridge Controller",
             vendor_id: 0x10C4,
             product_id: 0xEA60
           })

    assert Discover.serial_firmware_ambiguous?(%{
             description: "CP2102 USB to UART Bridge Controller"
           })

    assert Discover.serial_firmware_ambiguous?(%{path: "/dev/ttyUSB0"})

    assert Discover.serial_firmware_ambiguous?(wio)

    refute Discover.serial_firmware_ambiguous?(%{
             description: "T1000-E-BOOT",
             vendor_id: 0x239A,
             product_id: 0x8029
           })
  end

  test "keeps a probed island-bridge packet port even when the CLI sibling would also match" do
    probe = fn
      "/dev/ttyACM0", _ -> :bridge_cli
      "/dev/ttyACM1", _ -> :bridge_packet
      _, _ -> :unknown
    end

    roles =
      Discover.scan(
        enumerate: fn -> fake_ports() end,
        probe: probe,
        env: fn _ -> nil end
      )

    assert roles.bridge_cli.path == "/dev/ttyACM0"
    assert roles.bridge_packet.path == "/dev/ttyACM1"
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

  test "scan records USB open errors instead of leaving the port unidentified" do
    ports = %{
      "ttyUSB0" => %{
        description: "CP2102 USB to UART Bridge Controller",
        vendor_id: 0x10C4,
        product_id: 0xEA60
      }
    }

    roles =
      Discover.scan(
        enumerate: fn -> ports end,
        probe: fn "/dev/ttyUSB0", _ -> {:error, :eacces} end,
        env: fn _ -> nil end
      )

    assert roles.probe_errors["/dev/ttyUSB0"] == :eacces
    refute Map.has_key?(roles, :companion)
    refute Map.has_key?(roles, :meshtastic)
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

  test "keep_still_attached does not restore Meshtastic when the same port is now a MeshCore bridge" do
    previous = %{
      meshtastic: %{path: "/dev/ttyACM0", source: :detected, detail: nil},
      meshtastic_ports: [%{path: "/dev/ttyACM0", source: :detected, detail: nil}]
    }

    current = %{
      bridge_cli: %{path: "/dev/ttyACM0", source: :detected, detail: nil},
      bridge_packet: %{path: "/dev/ttyACM1", source: :detected, detail: nil}
    }

    restored =
      Discover.keep_still_attached(current, previous, ["/dev/ttyACM0", "/dev/ttyACM1"])

    refute Map.has_key?(restored, :meshtastic)
    refute Enum.any?(restored[:meshtastic_ports] || [], &(&1.path == "/dev/ttyACM0"))
    assert restored.bridge_cli.path == "/dev/ttyACM0"
    assert restored.bridge_packet.path == "/dev/ttyACM1"
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

  test "keep_still_attached does not restore a MeshCore island that was re-probed" do
    previous = %{
      bridge_cli: %{path: "/dev/ttyACM0", source: :detected, detail: nil},
      bridge_packet: %{path: "/dev/ttyACM1", source: :detected, detail: nil}
    }

    restored =
      Discover.keep_still_attached(
        %{meshtastic_ports: []},
        previous,
        ["/dev/ttyACM0", "/dev/ttyACM1"],
        skip_paths: []
      )

    refute Map.has_key?(restored, :bridge_cli)
    refute Map.has_key?(restored, :bridge_packet)
  end

  test "classify_probe_buffer ignores ESP32 boot noise that looks like DEVICE_INFO" do
    boot = "rst:0x1 (POWERON_RESET),boot:0x13\r\n>" <> <<1::little-16, 13>>
    assert Discover.classify_probe_buffer(boot) == :unknown
  end

  test "classify_probe_buffer ignores an echoed Meshtastic want_config ToRadio" do
    echo = MeshtasticProtocol.want_config_frame(0xDEADBEEF)
    assert Discover.classify_probe_buffer(echo) == :unknown
  end

  test "classify_probe_buffer prefers MeshCore CLI over an echoed want_config" do
    echo = MeshtasticProtocol.want_config_frame(1)
    cli = echo <> "-> v1.8.1 firmware\r\n"
    assert Discover.classify_probe_buffer(cli) == :bridge_cli
  end

  test "classify_probe_buffer treats an ESP32 Meshtastic boot stream as Meshtastic" do
    rebooted = <<0x94, 0xC3, 0x00, 0x02, 0x40, 0x01>>

    interleaved =
      "ESP-ROM:esp32s3-20210327\r\nentry 0x403c98d0\r\n" <>
        rebooted <>
        "\e[32mINFO  \e[0m| ??:??:?? 0 \e[32m\r\n\r\n//\\ E S H T /\\ S T / C\r\n"

    assert Discover.classify_probe_buffer(rebooted) == :meshtastic
    assert Discover.classify_probe_buffer(interleaved) == :meshtastic

    banner_only =
      "\r\n//\\ E S H T /\\ S T / C\r\nINFO  | Booted, wake cause 0 (boot count 1)\r\n"

    assert Discover.classify_probe_buffer(banner_only) == :meshtastic

    refute Discover.classify_probe_buffer("ESP-ROM:esp32s3-20210327\r\nload:0x3fce3808\r\n") ==
             :meshtastic
  end

  test "classify_probe_buffer treats any complete Meshtastic serial frame as Meshtastic" do
    metadata = MeshtasticProtocol.encode_frame(Protobuf.encode_message_field(13, <<>>))
    log_record = MeshtasticProtocol.encode_frame(Protobuf.encode_bytes_field(6, "boot"))

    my_info =
      MeshtasticProtocol.encode_frame(
        Protobuf.encode_message_field(3, Protobuf.encode_varint_field(1, 1))
      )

    assert Discover.classify_probe_buffer(metadata) == :meshtastic
    assert Discover.classify_probe_buffer(log_record) == :meshtastic
    assert Discover.classify_probe_buffer(my_info) == :meshtastic
  end

  test "classify_probe_buffer prefers a MeshCore CLI banner over Meshtastic frames" do
    metadata = MeshtasticProtocol.encode_frame(Protobuf.encode_message_field(13, <<>>))
    assert Discover.classify_probe_buffer(metadata <> "-> v1.8 firmware") == :bridge_cli
  end

  test "classify_probe_buffer prefers Meshtastic FromRadio over a spurious companion decode" do
    boot = ">" <> <<1::little-16, 13>>
    inner = Protobuf.encode_varint_field(1, 0xDEADBEEF)
    payload = Protobuf.encode_message_field(3, inner)
    meshtastic = MeshtasticProtocol.encode_frame(payload)

    assert Discover.classify_probe_buffer(boot <> meshtastic) == :meshtastic
  end

  test "classify_probe_buffer prefers a Meshtastic banner over a plausible DEVICE_INFO decoy" do
    rest = <<3, 100, 8>> <> :binary.copy(<<0>>, 77)
    frame = <<13, rest::binary>>
    decoy = <<">", byte_size(frame)::little-16, frame::binary>>
    banner = "\r\n//\\ E S H T /\\ S T / C\r\nINFO  | Booted, wake cause 0\r\n"

    assert Discover.classify_probe_buffer(decoy) == :companion
    assert Discover.classify_probe_buffer(decoy <> banner) == :meshtastic

    rebooted = <<0x94, 0xC3, 0x00, 0x02, 0x40, 0x01>>
    assert Discover.classify_probe_buffer(decoy <> rebooted) == :meshtastic
  end

  test "classify_probe_buffer accepts a MeshCore island-bridge packet frame" do
    {:ok, frame} = Isthmus.Networks.MeshCore.BridgeFrame.encode(<<1, 2, 3, 4>>)
    assert Discover.classify_probe_buffer(frame) == :bridge_packet
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
    assert Discover.cli_probe_reply?("  -> 1.8.1")
    assert Discover.cli_probe_reply?("ver\r\n  -> Unknown command")
  end

  test "refresh drops a radio when a later probe no longer classifies it" do
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
    refute Map.has_key?(roles, :meshtastic)
    assert roles.meshtastic_ports == []
  end
end
