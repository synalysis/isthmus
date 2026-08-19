defmodule Isthmus.Networks.MeshCore.Discover do
  @moduledoc """
  Detect which radios are attached to which serial ports.

  Roles:
  - `:companion` — MeshCore Companion Radio Protocol (framed `<`/`>` DEVICE_QUERY)
  - `:bridge_cli` — MeshCore repeater text CLI (`ver\\r` reply with `->`)
  - `:bridge_packet` — sibling CDC of a detected CLI, or `0xC0 0x3E` island-bridge framing
  - `:meshtastic` — Meshtastic serial API (FromRadio, including the boot
    `:rebooted` frame and the `MESHTASTIC` banner; not a ToRadio echo)
  - `:rnode` — Reticulum RNode KISS detect (`FEND CMD_DETECT DETECT_RESP`)

  Environment variables override detection when set:
  - `ISTHMUS_MESHCORE_PORT`
  - `ISTHMUS_MESHCORE_BRIDGE_CLI_PORT`
  - `ISTHMUS_MESHCORE_BRIDGE_PORT`
  - `ISTHMUS_MESHTASTIC_PORT`

  Discovery runs at boot before Companion / BridgeCLI / BridgeLink / Meshtastic
  Companion open ports. Call `refresh/0` after hotplug or a repeater reboot.
  """
  use GenServer

  require Logger

  alias Isthmus.Networks.MeshCore.BridgeFrame
  alias Isthmus.Networks.MeshCore.Ports
  alias Isthmus.Networks.MeshCore.Protocol
  alias Isthmus.Networks.Meshtastic.Protocol, as: MeshtasticProtocol
  alias Isthmus.Networks.Reticulum.RNode

  @table :isthmus_meshcore_discover
  @baud 115_200
  @probe_timeout_ms 500
  @meshtastic_probe_ms 3_000
  @open_timeout_ms 1_500
  # Opening a CP210x/CH340 pulses DTR and resets ESP32. The radio emits a
  # FromRadio `:rebooted` frame plus the boot banner during that window.
  # Docker USB passthrough is often slower than a native host open.
  @uart_boot_ms 3_000
  @acm_idle_ms 400
  @write_timeout_ms 400

  @type role :: :companion | :bridge_cli | :bridge_packet | :meshtastic | :rnode
  @type assignment :: %{
          path: String.t(),
          source: :env | :detected,
          detail: term()
        }

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Map of role => assignment for the given Discover process."
  def roles(name \\ __MODULE__) do
    case safe_call(name, :roles, nil) do
      nil -> read_ets(name) || %{}
      roles -> roles
    end
  end

  @doc "Port path for a role, or nil."
  def role(role, name \\ __MODULE__)
      when role in [:companion, :bridge_cli, :bridge_packet, :meshtastic, :rnode] do
    case roles(name)[role] do
      %{path: path} when is_binary(path) and path != "" -> path
      _ -> nil
    end
  end

  @doc """
  Resolve the port for a role: env override if set, else discovered path.

  Options:
  - `:env` — override env lookup (tests)
  - `:discover` — Discover process name
  """
  def resolve_port(role, opts \\ [])

  def resolve_port(:companion, opts) do
    env = Keyword.get(opts, :env, &System.get_env/1)
    name = Keyword.get(opts, :discover, __MODULE__)
    first_present([env.("ISTHMUS_MESHCORE_PORT"), role(:companion, name)])
  end

  def resolve_port(:bridge_cli, opts) do
    env = Keyword.get(opts, :env, &System.get_env/1)
    name = Keyword.get(opts, :discover, __MODULE__)
    first_present([env.("ISTHMUS_MESHCORE_BRIDGE_CLI_PORT"), role(:bridge_cli, name)])
  end

  def resolve_port(:bridge_packet, opts) do
    env = Keyword.get(opts, :env, &System.get_env/1)
    name = Keyword.get(opts, :discover, __MODULE__)
    first_present([env.("ISTHMUS_MESHCORE_BRIDGE_PORT"), role(:bridge_packet, name)])
  end

  def resolve_port(:meshtastic, opts) do
    env = Keyword.get(opts, :env, &System.get_env/1)
    name = Keyword.get(opts, :discover, __MODULE__)
    first_present([env.("ISTHMUS_MESHTASTIC_PORT"), role(:meshtastic, name)])
  end

  @doc "All companion ports (env pin first, then every detected radio)."
  def resolve_ports(role, opts \\ [])

  def resolve_ports(:meshtastic, opts) do
    env = Keyword.get(opts, :env, &System.get_env/1)
    name = Keyword.get(opts, :discover, __MODULE__)
    env_port = blank_to_nil(env.("ISTHMUS_MESHTASTIC_PORT"))
    roles = roles(name)

    detected =
      (roles[:meshtastic_ports] || [])
      |> Enum.map(fn
        %{path: path} -> path
        path when is_binary(path) -> path
        _ -> nil
      end)
      |> Enum.filter(&(is_binary(&1) and &1 != ""))

    [env_port, role(:meshtastic, name) | detected]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  def resolve_ports(:companion, opts) do
    env = Keyword.get(opts, :env, &System.get_env/1)
    name = Keyword.get(opts, :discover, __MODULE__)
    env_port = blank_to_nil(env.("ISTHMUS_MESHCORE_PORT"))
    roles = roles(name)

    detected =
      (roles[:companion_ports] || [])
      |> Enum.map(fn
        %{path: path} -> path
        path when is_binary(path) -> path
        _ -> nil
      end)
      |> Enum.filter(&(is_binary(&1) and &1 != ""))

    [env_port, role(:companion, name) | detected]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @doc """
  Re-scan unclaimed serial ports and attach any new radios.

  Companions that are already online keep their UART — reopening CP210x/CH340
  pulses DTR and reboots ESP32 Meshtastic firmware.
  """
  def refresh(name \\ __MODULE__) do
    case safe_call(name, :refresh, {:error, :not_started}, 15_000) do
      {:ok, roles} ->
        notify_reconnect()
        {:ok, roles}

      other ->
        other
    end
  end

  @doc false
  def keep_still_attached(roles, previous, present, opts \\ [])
      when is_map(roles) and is_map(previous) and is_list(opts) do
    present = MapSet.new(present)
    # Ports we did not re-probe stay classified. A port that was probed and
    # came back unknown must not keep a stale MeshCore island assignment —
    # the same Wio USB identity is used by Meshtastic.
    skipped = MapSet.new(Keyword.get(opts, :skip_paths, MapSet.to_list(present)))

    roles =
      roles
      |> restore_singletons(previous, present, skipped)
      |> restore_port_list(:meshtastic_ports, previous, present, skipped)
      |> restore_port_list(:companion_ports, previous, present, skipped)
      |> restore_port_list(:rnode_ports, previous, present, skipped)

    roles
    |> Map.put(
      :meshtastic_ports,
      merge_port_list(roles[:meshtastic_ports], roles[:meshtastic])
    )
    |> Map.put(
      :companion_ports,
      merge_port_list(roles[:companion_ports], roles[:companion])
    )
  end

  @doc """
  Pure scan used by the GenServer and by tests.

  Options:
  - `:enumerate` — `fn -> %{name => meta}` (default Circuits.UART.enumerate/0)
  - `:probe` — `fn path, meta -> :companion | :bridge_cli | :meshtastic | :rnode | :unknown | {:error, term}`
  - `:env` — `fn key -> value | nil`
  - `:skip_paths` — ports to leave alone (already open elsewhere)
  """
  def scan(opts \\ []) do
    enumerate = Keyword.get(opts, :enumerate, &Circuits.UART.enumerate/0)
    probe = Keyword.get(opts, :probe, &default_probe/2)
    env = Keyword.get(opts, :env, &System.get_env/1)
    skip = MapSet.new(Keyword.get(opts, :skip_paths, []))

    env_companion = blank_to_nil(env.("ISTHMUS_MESHCORE_PORT"))
    env_cli = blank_to_nil(env.("ISTHMUS_MESHCORE_BRIDGE_CLI_PORT"))
    env_packet = blank_to_nil(env.("ISTHMUS_MESHCORE_BRIDGE_PORT"))
    env_meshtastic = blank_to_nil(env.("ISTHMUS_MESHTASTIC_PORT"))

    ports =
      Ports.list(enumerate: enumerate, configured: env_companion)
      |> Enum.reject(fn p -> MapSet.member?(skip, p.path) end)

    by_path = Map.new(ports, &{&1.path, &1})
    Logger.info("MeshCore discover: probing #{length(ports)} port(s)")

    {detected, claimed} =
      Enum.reduce(
        ports,
        {%{meshtastic_ports: [], rnode_ports: [], companion_ports: []}, MapSet.new()},
        fn port, {acc, claimed} ->
          cond do
            MapSet.member?(claimed, port.path) ->
              {acc, claimed}

            env_companion == port.path or env_cli == port.path or env_packet == port.path ->
              {acc, MapSet.put(claimed, port.path)}

            env_meshtastic == port.path ->
              entry = %{path: port.path, source: :env, detail: port}
              {add_meshtastic(acc, entry), MapSet.put(claimed, port.path)}

            true ->
              case probe.(port.path, port) do
                :companion ->
                  Logger.info("MeshCore discover: #{port.path} -> companion")
                  entry = %{path: port.path, source: :detected, detail: port}
                  {add_companion(acc, entry), MapSet.put(claimed, port.path)}

                :bridge_cli ->
                  Logger.info("MeshCore discover: #{port.path} -> bridge_cli")

                  {Map.put(acc, :bridge_cli, %{path: port.path, source: :detected, detail: port}),
                   MapSet.put(claimed, port.path)}

                :bridge_packet ->
                  Logger.info("MeshCore discover: #{port.path} -> bridge_packet")

                  entry = %{path: port.path, source: :detected, detail: port}

                  {Map.put_new(acc, :bridge_packet, entry), MapSet.put(claimed, port.path)}

                :meshtastic ->
                  Logger.info("MeshCore discover: #{port.path} -> meshtastic")
                  entry = %{path: port.path, source: :detected, detail: port}
                  {add_meshtastic(acc, entry), MapSet.put(claimed, port.path)}

                :rnode ->
                  Logger.info("MeshCore discover: #{port.path} -> rnode")
                  entry = %{path: port.path, source: :detected, detail: port}
                  {add_rnode(acc, entry), MapSet.put(claimed, port.path)}

                other ->
                  acc =
                    case other do
                      {:error, reason} ->
                        Map.update(acc, :probe_errors, %{port.path => reason}, fn errs ->
                          Map.put(errs, port.path, reason)
                        end)

                      _ ->
                        acc
                    end

                  Logger.debug("MeshCore discover: #{port.path} -> #{inspect(other)}")
                  {acc, claimed}
              end
          end
        end
      )

    roles =
      %{}
      |> put_role(:companion, env_companion, detected[:companion], :env)
      |> put_role(:bridge_cli, env_cli, detected[:bridge_cli], :env)
      |> put_role(:meshtastic, env_meshtastic, detected[:meshtastic], :env)
      |> maybe_packet(
        env_packet,
        detected[:bridge_cli],
        by_path,
        claimed,
        detected[:bridge_packet]
      )

    roles
    |> Map.put(
      :meshtastic_ports,
      merge_port_list(detected[:meshtastic_ports], roles[:meshtastic])
    )
    |> Map.put(
      :companion_ports,
      merge_port_list(detected[:companion_ports], roles[:companion])
    )
    |> Map.put(:rnode_ports, detected[:rnode_ports] || [])
    |> Map.put(:probe_errors, detected[:probe_errors] || %{})
    |> maybe_primary_rnode(detected[:rnode])
  end

  @impl true
  def init(opts) do
    table = ensure_ets(@table)
    name = Keyword.get(opts, :name, __MODULE__)

    app_opts = Application.get_env(:isthmus, __MODULE__, [])
    opts = Keyword.merge(app_opts, opts)

    state = %{
      name: name,
      table: table,
      opts: Keyword.take(opts, [:enumerate, :probe, :env, :skip_paths]),
      roles: %{}
    }

    # Never block OTP boot on USB probes — a hung ACM open exceeds the
    # supervisor start timeout and takes the whole Networks tree down.
    publish(state, %{})
    {:ok, state, {:continue, :boot_scan}}
  end

  @impl true
  def handle_continue(:boot_scan, state) do
    roles = scan(state.opts)
    publish(state, roles)
    Logger.info("MeshCore discover: #{format_roles(roles)}")
    notify_reconnect()
    {:noreply, %{state | roles: roles}}
  end

  @impl true
  def handle_call(:roles, _from, state), do: {:reply, state.roles, state}

  def handle_call(:refresh, _from, state) do
    _ =
      try do
        Isthmus.Networks.MeshCore.Companion.disconnect_unidentified()
        Isthmus.Networks.Meshtastic.Companion.disconnect_unidentified()
        # Do not drop a Discover-assigned island CLI just because `get radio`
        # has not parsed yet. That used to free Wio ports stolen as MeshCore
        # by USB identity; it now leaves a real bridge sitting Offline.
      catch
        :exit, _ -> :ok
      end

    claimed = claimed_serial_paths()
    present = current_serial_paths(state.opts)
    skip = Enum.uniq(List.wrap(Keyword.get(state.opts, :skip_paths, [])) ++ claimed)

    roles =
      state.opts
      |> Keyword.put(:skip_paths, skip)
      |> scan()
      |> keep_still_attached(state.roles, present, skip_paths: skip)

    publish(state, roles)
    Logger.info("MeshCore discover refresh: #{format_roles(roles)}")
    {:reply, {:ok, roles}, %{state | roles: roles}}
  end

  defp put_role(roles, role, env_path, detected, :env) when is_binary(env_path) do
    Map.put(roles, role, %{path: env_path, source: :env, detail: detected && detected.detail})
  end

  defp put_role(roles, _role, _env, nil, _), do: roles

  defp put_role(roles, role, _env, detected, _), do: Map.put(roles, role, detected)

  defp maybe_packet(roles, env_packet, _cli, _by_path, _claimed, _probed)
       when is_binary(env_packet) do
    Map.put(roles, :bridge_packet, %{path: env_packet, source: :env, detail: nil})
  end

  defp maybe_packet(roles, _env, _cli, _by_path, _claimed, %{path: path} = probed)
       when is_binary(path) do
    Map.put(roles, :bridge_packet, probed)
  end

  defp maybe_packet(roles, _env, %{path: cli_path, detail: detail}, by_path, claimed, _probed) do
    case sibling_packet_path(cli_path, detail, by_path, claimed) do
      nil ->
        roles

      path ->
        Map.put(roles, :bridge_packet, %{
          path: path,
          source: :detected,
          detail: Map.get(by_path, path)
        })
    end
  end

  defp maybe_packet(roles, _, _, _, _, _), do: roles

  defp sibling_packet_path(cli_path, detail, by_path, claimed) do
    serial = detail && detail.serial_number

    candidates =
      by_path
      |> Map.values()
      |> Enum.reject(fn p -> p.path == cli_path or MapSet.member?(claimed, p.path) end)
      |> Enum.filter(fn p ->
        acm_like?(p.path) and
          (is_binary(serial) and serial != "" and p.serial_number == serial)
      end)
      |> Enum.sort_by(& &1.path)

    case candidates do
      [%{path: path} | _] ->
        path

      [] ->
        # Fall back: next ACM sibling by name (ttyACM0 → ttyACM1).
        case next_acm_sibling(cli_path) do
          path when is_binary(path) ->
            if Map.has_key?(by_path, path) and not MapSet.member?(claimed, path), do: path

          _ ->
            nil
        end
    end
  end

  # Same USB identity (Seeed Wio Tracker L1) is used by Meshtastic firmware
  # and by MeshCore island-bridge firmware. Identity alone is not a role.
  @doc false
  def ambiguous_nrf_board?(port) when is_map(port) do
    desc =
      [port[:description], port[:manufacturer]]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
      |> String.downcase()

    cond do
      String.contains?(desc, "boot") ->
        false

      port[:vendor_id] == 0x2886 and port[:product_id] in [0x1667, 0x0057] ->
        true

      # Adafruit TinyUSB CDC used by T1000-E application firmware (not DFU).
      port[:vendor_id] == 0x239A ->
        true

      String.contains?(desc, "wio tracker") ->
        true

      String.contains?(desc, "t1000") ->
        true

      true ->
        false
    end
  end

  def ambiguous_nrf_board?(_), do: false

  # CP210x / CH340 / FTDI / Espressif native USB: MeshCore companion *or*
  # Meshtastic. `ver\r` first desyncs the protobuf parser the same way it
  # does on the Wio.
  @usb_uart_vids [0x10C4, 0x1A86, 0x0403, 0x303A]

  @doc false
  def serial_firmware_ambiguous?(port) when is_map(port) do
    ambiguous_nrf_board?(port) or usb_uart_bridge?(port)
  end

  def serial_firmware_ambiguous?(_), do: false

  defp usb_uart_bridge?(port) when is_map(port) do
    vid = port[:vendor_id]

    desc =
      [port[:description], port[:manufacturer], port[:path], port[:name]]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
      |> String.downcase()

    # Docker --device=/dev/ttyUSB0 often has no udev vendor_id. The CP2102
    # product string (or ttyUSB path) still marks an ESP32 USB-UART board.
    (is_integer(vid) and vid in @usb_uart_vids) or
      String.contains?(desc, "cp210") or
      String.contains?(desc, "ch340") or
      String.contains?(desc, "ch341") or
      String.contains?(desc, "silicon labs") or
      String.contains?(desc, "qinheng") or
      String.contains?(desc, "ftdi") or
      String.contains?(desc, "ttyusb")
  end

  defp acm_like?(path) do
    Isthmus.Networks.Uart.acm?(path)
  end

  defp next_acm_sibling(path) do
    case Regex.run(~r/^(.*ttyACM)(\d+)$/, path) do
      [_, prefix, num] ->
        prefix <> Integer.to_string(String.to_integer(num) + 1)

      _ ->
        nil
    end
  end

  defp default_probe(path, meta) do
    Application.ensure_all_started(:circuits_uart)
    prev_trap = Process.flag(:trap_exit, true)

    try do
      case Circuits.UART.start_link() do
        {:ok, uart} ->
          try do
            case open_with_timeout(uart, path, @open_timeout_ms) do
              :ok ->
                Isthmus.Networks.Uart.prepare(uart, path)
                sibling = hold_pair_sibling(path, meta)

                try do
                  classify_port(uart, meta)
                after
                  Isthmus.Networks.Uart.release(sibling)
                end

              {:error, reason} ->
                Logger.warning("MeshCore discover: open #{path} failed: #{inspect(reason)}")
                {:error, reason}
            end
          catch
            :exit, reason ->
              Logger.warning("MeshCore discover: probe #{path} UART exited: #{inspect(reason)}")

              :unknown
          after
            Isthmus.Networks.Uart.release(uart)

            receive do
              {:EXIT, ^uart, _} -> :ok
            after
              200 -> :ok
            end
          end

        {:error, _} ->
          :unknown
      end
    after
      Process.flag(:trap_exit, prev_trap)
    end
  rescue
    _ -> :unknown
  end

  defp open_with_timeout(uart, path, ms) do
    parent = self()
    ref = make_ref()

    opener =
      spawn(fn ->
        result =
          try do
            # Leave DTR/RTS clear so ESP32 boards behind CP210x/CH340 do not
            # reset into the bootloader for the whole probe window.
            # DTR is applied after open via Uart.prepare/2 (not an open option).
            Circuits.UART.open(uart, path, speed: @baud, active: false)
          catch
            :exit, reason -> {:error, {:exit, reason}}
          end

        send(parent, {ref, result})
      end)

    receive do
      {^ref, result} -> result
    after
      ms ->
        Process.exit(opener, :kill)
        {:error, :open_timeout}
    end
  end

  defp classify_port(uart, meta) do
    # Do not flush. Opening CP210x/CH340 pulses DTR and the ESP32 Meshtastic
    # firmware immediately sends FromRadio `:rebooted` plus the boot banner.
    # Flushing that away leaves want_config landing in the ROM bootloader.
    idle_ms = if serial_firmware_ambiguous?(meta), do: @uart_boot_ms, else: @acm_idle_ms
    # DEVICE_INFO is a reply to DEVICE_QUERY. Accepting companion during the
    # idle window lets ESP32 boot noise steal a Meshtastic CP2102, especially
    # in Docker where the first open always pulses DTR.
    accept =
      if serial_firmware_ambiguous?(meta) do
        [:meshtastic, :bridge_cli, :bridge_packet]
      else
        [:companion, :bridge_cli, :bridge_packet, :meshtastic]
      end

    {kind, acc} = read_until_kind(uart, idle_ms, <<>>, accept)

    case kind do
      kind when kind in [:companion, :bridge_cli, :bridge_packet, :meshtastic] ->
        kind

      _ ->
        classify_after_idle(uart, acc, meta)
    end
  end

  defp classify_after_idle(uart, acc, meta) do
    if serial_firmware_ambiguous?(meta) do
      # `ver\r` first desyncs Meshtastic's protobuf parser on boards that also
      # run MeshCore. Ask for FromRadio first; recover a CLI line with `\rver\r`
      # only if that stays quiet.
      nonce = :rand.uniform(0x7FFF_FFFE) + 1
      _ = probe_write(uart, MeshtasticProtocol.want_config_frame(nonce))
      {kind, acc} = read_until_kind(uart, @meshtastic_probe_ms, acc)

      case kind do
        kind when kind in [:companion, :bridge_cli, :bridge_packet, :meshtastic] ->
          kind

        _ ->
          classify_after_initial(uart, acc, nonce)
      end
    else
      # Repeater CLI first. Binary MeshCore/Meshtastic probes fill the 160-byte
      # command buffer and get echoed; `ver` must land on a clean line.
      _ = probe_write(uart, "ver\r")
      {kind, acc} = read_until_kind(uart, @probe_timeout_ms, acc)

      case kind do
        kind when kind in [:companion, :bridge_cli, :bridge_packet, :meshtastic] ->
          kind

        _ ->
          classify_after_initial(uart, acc, nil)
      end
    end
  end

  defp classify_after_initial(uart, acc, nonce) do
    companion_frame = Protocol.encode_usb_frame(Protocol.device_query_frame())
    nonce = nonce || :rand.uniform(0x7FFF_FFFE) + 1
    meshtastic_frame = MeshtasticProtocol.want_config_frame(nonce)
    _ = probe_write(uart, companion_frame)
    _ = probe_write(uart, meshtastic_frame)
    _ = probe_write(uart, "\rver\r")

    {kind, acc} = read_until_kind(uart, @probe_timeout_ms, acc)

    case kind do
      kind when kind in [:companion, :bridge_cli, :bridge_packet, :meshtastic] ->
        kind

      _ ->
        _ = probe_write(uart, MeshtasticProtocol.want_config_frame(nonce))
        {kind, acc} = read_until_kind(uart, @meshtastic_probe_ms, acc)

        case kind do
          kind when kind in [:companion, :bridge_cli, :bridge_packet, :meshtastic] ->
            kind

          _ ->
            _ = probe_write(uart, RNode.detect_frame())

            {rnode?, acc} =
              read_until_pred(uart, &RNode.detect_response?/1, @probe_timeout_ms, acc)

            cond do
              classified = classified_role(acc) ->
                classified

              rnode? ->
                :rnode

              true ->
                _ = probe_write(uart, "ver\r")
                {cli?, acc} = read_until_pred(uart, &cli_response?/1, @probe_timeout_ms, acc)

                cond do
                  classified = classified_role(acc) -> classified
                  cli? -> :bridge_cli
                  true -> :unknown
                end
            end
        end
    end
  end

  defp probe_write(uart, data) do
    Circuits.UART.write(uart, data, @write_timeout_ms)
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp hold_pair_sibling(path, meta) do
    serial = meta[:serial_number]

    if ambiguous_nrf_board?(meta) and is_binary(serial) and serial != "" do
      case pair_sibling_path(path, serial) do
        nil ->
          nil

        sibling_path ->
          case Circuits.UART.start_link() do
            {:ok, uart} ->
              case open_with_timeout(uart, sibling_path, 800) do
                :ok ->
                  Isthmus.Networks.Uart.prepare(uart, sibling_path)
                  uart

                _ ->
                  Isthmus.Networks.Uart.release(uart)
                  nil
              end

            _ ->
              nil
          end
      end
    end
  end

  defp pair_sibling_path(path, serial) do
    Enum.find_value(Circuits.UART.enumerate(), fn {name, other} ->
      other = other || %{}
      p = uart_dev_path(name)

      if p != path and other[:serial_number] == serial and acm_like?(p) do
        p
      end
    end)
  end

  defp uart_dev_path(name) do
    name = to_string(name)
    if String.starts_with?(name, "/"), do: name, else: "/dev/#{name}"
  end

  @doc false
  def classify_probe_buffer(data) when is_binary(data), do: classified_role(data) || :unknown

  def classify_probe_buffer(_), do: :unknown

  defp classified_role(data) when is_binary(data) do
    cond do
      # Repeater CLIs echo want_config and prefix replies with "->".
      cli_response?(data) ->
        :bridge_cli

      # ESP32 Meshtastic boot logs often contain `>` / CR that decode as a
      # MeshCore DEVICE_INFO frame. A real companion never emits FromRadio or
      # the MESHTASTIC banner, so those win when both are in the buffer.
      meshtastic_response?(data) or meshtastic_boot_banner?(data) ->
        :meshtastic

      companion_response?(data) ->
        :companion

      bridge_packet_response?(data) ->
        :bridge_packet

      true ->
        nil
    end
  end

  defp classified_role(_), do: nil

  @doc false
  def cli_probe_reply?(data), do: cli_response?(data)

  defp companion_response?(data) when is_binary(data) do
    {frames, _} = Protocol.decode_usb_stream(data)
    Enum.any?(frames, &Protocol.companion_probe_reply?/1)
  end

  defp cli_response?(data) when is_binary(data) do
    # MeshCore repeater CLI prefixes replies with "->". Bare tokens like
    # "firmware" appear in Meshtastic logs and protobuf dumps.
    down = String.downcase(data)

    String.contains?(down, "->") and
      (String.contains?(down, "v1.") or
         String.contains?(down, "build:") or
         String.contains?(down, "firmware") or
         String.contains?(down, "ver") or
         String.contains?(down, "unknown command") or
         Regex.match?(~r/\d+\.\d+/, down))
  end

  defp cli_response?(_), do: false

  defp bridge_packet_response?(data) when is_binary(data) do
    {packets, _, _} = BridgeFrame.decode(data)
    packets != []
  end

  defp meshtastic_response?(data) when is_binary(data) do
    {frames, _} = MeshtasticProtocol.decode_stream(data)
    Enum.any?(frames, &MeshtasticProtocol.probe_from_radio?/1)
  end

  defp meshtastic_boot_banner?(data) when is_binary(data) do
    down = String.downcase(data)

    String.contains?(down, "meshtastic") or
      String.contains?(data, "E S H T") or
      String.contains?(down, "booted, wake cause")
  end

  @accept_all_roles [:companion, :bridge_cli, :bridge_packet, :meshtastic]

  defp read_until_kind(uart, timeout_ms, acc, accept \\ @accept_all_roles) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_read_until_kind(uart, deadline, acc, accept)
  end

  defp do_read_until_kind(uart, deadline, acc, accept) do
    remaining = deadline - System.monotonic_time(:millisecond)
    kind = classified_role(acc)

    cond do
      kind in accept ->
        {kind, acc}

      remaining <= 0 ->
        {:unknown, acc}

      true ->
        chunk =
          case Circuits.UART.read(uart, min(max(remaining, 1), 200)) do
            {:ok, data} when is_binary(data) -> data
            _ -> <<>>
          end

        acc = acc <> chunk

        if chunk == "" and remaining > 0, do: Process.sleep(min(40, remaining))
        do_read_until_kind(uart, deadline, acc, accept)
    end
  end

  defp read_until_pred(uart, pred, timeout_ms, acc) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_read_until_pred(uart, pred, deadline, acc)
  end

  defp do_read_until_pred(uart, pred, deadline, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)
    matched? = pred.(acc)

    cond do
      remaining <= 0 ->
        {matched?, acc}

      matched? ->
        {true, acc}

      true ->
        chunk =
          case Circuits.UART.read(uart, min(max(remaining, 1), 200)) do
            {:ok, data} when is_binary(data) -> data
            _ -> <<>>
          end

        acc = acc <> chunk

        if chunk == "" and remaining > 0, do: Process.sleep(min(40, remaining))
        do_read_until_pred(uart, pred, deadline, acc)
    end
  end

  defp publish(state, roles) do
    :ets.insert(state.table, {{:roles, state.name}, roles})
    roles
  end

  defp read_ets(name) do
    case :ets.whereis(@table) do
      :undefined ->
        nil

      table ->
        case :ets.lookup(table, {:roles, name}) do
          [{{:roles, ^name}, roles}] -> roles
          _ -> nil
        end
    end
  rescue
    _ -> nil
  end

  defp ensure_ets(name) do
    case :ets.whereis(name) do
      :undefined -> :ets.new(name, [:named_table, :public, :set, read_concurrency: true])
      table -> table
    end
  end

  defp notify_reconnect do
    for mod <- [
          Isthmus.Networks.MeshCore.Companion,
          Isthmus.Networks.MeshCore.BridgeCLI,
          Isthmus.Networks.MeshCore.BridgeLink,
          Isthmus.Networks.Meshtastic.Companion
        ] do
      if function_exported?(mod, :reconnect, 0) do
        try do
          mod.reconnect()
        catch
          :exit, _ -> :ok
        end
      end
    end

    if Code.ensure_loaded?(Isthmus.Networks.MeshCore.Supervisor) and
         function_exported?(Isthmus.Networks.MeshCore.Supervisor, :sync, 0) do
      try do
        Isthmus.Networks.MeshCore.Supervisor.sync()
      catch
        :exit, _ -> :ok
      end
    end

    reconnect_disconnected_meshcore_extras()
    reconnect_disconnected_meshtastic_extras()

    if Code.ensure_loaded?(Isthmus.Networks.Meshtastic.Supervisor) and
         function_exported?(Isthmus.Networks.Meshtastic.Supervisor, :sync, 0) do
      try do
        Isthmus.Networks.Meshtastic.Supervisor.sync()
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  defp reconnect_disconnected_meshtastic_extras do
    primary = Isthmus.Networks.MeshCore.Discover.resolve_port(:meshtastic)

    Isthmus.Networks.Meshtastic.Companion.list_health()
    |> Enum.each(fn health ->
      port = health[:port]

      if is_binary(port) and port != "" and port != primary and
           health[:status] in [:disconnected, :error] do
        Isthmus.Networks.Meshtastic.Companion.reconnect(port)
      end
    end)
  rescue
    _ -> :ok
  end

  defp reconnect_disconnected_meshcore_extras do
    primary = Isthmus.Networks.MeshCore.Discover.resolve_port(:companion)

    Isthmus.Networks.MeshCore.Companion.list_health()
    |> Enum.each(fn health ->
      port = health[:port]

      if is_binary(port) and port != "" and port != primary and
           health[:primary?] != true and
           health[:status] in [:disconnected, :error] do
        Isthmus.Networks.MeshCore.Companion.reconnect(port)
      end
    end)
  rescue
    _ -> :ok
  end

  defp first_present(list) do
    Enum.find_value(list, fn
      path when is_binary(path) and path != "" -> path
      _ -> nil
    end)
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v

  defp format_roles(roles) do
    formatted =
      roles
      |> Enum.flat_map(fn
        {:companion_ports, list} when is_list(list) ->
          Enum.map(list, fn
            %{path: path, source: source} -> "companion=#{path}(#{source})"
            _ -> nil
          end)
          |> Enum.reject(&is_nil/1)

        {:meshtastic_ports, list} when is_list(list) ->
          Enum.map(list, fn
            %{path: path, source: source} -> "meshtastic=#{path}(#{source})"
            _ -> nil
          end)
          |> Enum.reject(&is_nil/1)

        {:rnode_ports, list} when is_list(list) ->
          Enum.map(list, fn
            %{path: path, source: source} -> "rnode=#{path}(#{source})"
            _ -> nil
          end)
          |> Enum.reject(&is_nil/1)

        {:companion, _} ->
          []

        {:rnode, _} ->
          []

        {role, %{path: path, source: source}} ->
          ["#{role}=#{path}(#{source})"]

        _ ->
          []
      end)

    if formatted == [], do: "(none)", else: Enum.join(formatted, " ")
  end

  defp add_companion(acc, entry) do
    acc
    |> Map.update(:companion_ports, [entry], fn list ->
      if Enum.any?(list, &(&1.path == entry.path)), do: list, else: list ++ [entry]
    end)
    |> Map.put_new(:companion, entry)
  end

  defp add_meshtastic(acc, entry) do
    acc
    |> Map.update(:meshtastic_ports, [entry], fn list ->
      if Enum.any?(list, &(&1.path == entry.path)), do: list, else: list ++ [entry]
    end)
    |> Map.put_new(:meshtastic, entry)
  end

  defp add_rnode(acc, entry) do
    acc
    |> Map.update(:rnode_ports, [entry], fn list ->
      if Enum.any?(list, &(&1.path == entry.path)), do: list, else: list ++ [entry]
    end)
    |> Map.put_new(:rnode, entry)
  end

  defp maybe_primary_rnode(roles, nil), do: roles
  defp maybe_primary_rnode(roles, entry), do: Map.put_new(roles, :rnode, entry)

  @singleton_roles [:companion, :bridge_cli, :bridge_packet, :meshtastic, :rnode]

  defp restore_singletons(roles, previous, present, skipped) do
    Enum.reduce(@singleton_roles, roles, fn role, acc ->
      prev = previous[role]

      cond do
        match?(%{path: _}, acc[role]) ->
          acc

        is_map(prev) and is_binary(prev[:path]) and MapSet.member?(present, prev.path) and
          MapSet.member?(skipped, prev.path) and
            not MapSet.member?(assigned_paths(acc), prev.path) ->
          Map.put(acc, role, prev)

        true ->
          acc
      end
    end)
  end

  defp restore_port_list(roles, key, previous, present, skipped) do
    current = roles[key] || []
    taken = assigned_paths(roles)

    extra =
      (previous[key] || [])
      |> Enum.filter(fn
        %{path: path} ->
          is_binary(path) and MapSet.member?(present, path) and
            MapSet.member?(skipped, path) and not MapSet.member?(taken, path)

        _ ->
          false
      end)

    Map.put(roles, key, current ++ extra)
  end

  defp assigned_paths(roles) when is_map(roles) do
    roles
    |> Enum.flat_map(fn
      {:errors, _} ->
        []

      {_key, %{path: path}} when is_binary(path) and path != "" ->
        [path]

      {_key, list} when is_list(list) ->
        Enum.flat_map(list, fn
          %{path: path} when is_binary(path) and path != "" -> [path]
          path when is_binary(path) and path != "" -> [path]
          _ -> []
        end)

      _ ->
        []
    end)
    |> MapSet.new()
  end

  defp current_serial_paths(opts) do
    enumerate = Keyword.get(opts, :enumerate, &Circuits.UART.enumerate/0)
    env = Keyword.get(opts, :env, &System.get_env/1)

    Ports.list(enumerate: enumerate, configured: env.("ISTHMUS_MESHCORE_PORT"))
    |> Enum.map(& &1.path)
  end

  defp claimed_serial_paths do
    meshcore =
      try do
        Isthmus.Networks.MeshCore.Companion.list_health()
        |> Enum.map(fn
          %{status: status, port: port, self_ref: ref}
          when status in [:online, :live, :running] and is_binary(port) and port != "" and
                 is_binary(ref) and ref != "" ->
            port

          _ ->
            nil
        end)
      catch
        :exit, _ ->
          Enum.map(
            [
              Isthmus.Networks.MeshCore.Companion,
              Isthmus.Networks.MeshCore.BridgeCLI,
              Isthmus.Networks.MeshCore.BridgeLink
            ],
            &online_adapter_port/1
          )
      end

    meshcore_links =
      Enum.map(
        [
          Isthmus.Networks.MeshCore.BridgeCLI,
          Isthmus.Networks.MeshCore.BridgeLink
        ],
        &online_adapter_port/1
      )

    meshtastic =
      try do
        Isthmus.Networks.Meshtastic.Companion.list_health()
        |> Enum.map(fn
          %{status: status, port: port}
          when status in [:online, :live, :running] and is_binary(port) and port != "" ->
            port

          _ ->
            nil
        end)
      catch
        :exit, _ -> []
      end

    Enum.uniq(
      Enum.filter(meshcore ++ meshcore_links ++ meshtastic, &(is_binary(&1) and &1 != ""))
    )
  end

  defp online_adapter_port(mod) do
    try do
      case mod.health() do
        %{status: status, port: port}
        when status in [:online, :live, :running] and is_binary(port) and port != "" ->
          port

        _ ->
          nil
      end
    catch
      :exit, _ -> nil
    end
  end

  defp merge_port_list(detected, primary) do
    list = detected || []

    case primary do
      %{path: path} = entry ->
        if Enum.any?(list, &(&1.path == path)), do: list, else: [entry | list]

      _ ->
        list
    end
  end

  defp safe_call(name, request, fallback, timeout \\ 2_000) do
    GenServer.call(name, request, timeout)
  catch
    :exit, _ -> fallback
  end
end
