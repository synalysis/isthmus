defmodule Isthmus.Networks.MeshCore.Discover do
  @moduledoc """
  Detect which radios are attached to which serial ports.

  Roles:
  - `:companion` — MeshCore Companion Radio Protocol (framed `<`/`>` DEVICE_QUERY)
  - `:bridge_cli` — MeshCore repeater text CLI (`ver\\r`)
  - `:bridge_packet` — sibling CDC of a detected CLI (or env override)
  - `:meshtastic` — Meshtastic serial API (`0x94 0xC3` protobuf want_config)

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

  alias Isthmus.Networks.MeshCore.Ports
  alias Isthmus.Networks.MeshCore.Protocol
  alias Isthmus.Networks.Meshtastic.Protocol, as: MeshtasticProtocol

  @table :isthmus_meshcore_discover
  @baud 115_200
  @probe_timeout_ms 500
  @open_timeout_ms 1_500

  @type role :: :companion | :bridge_cli | :bridge_packet | :meshtastic
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
      when role in [:companion, :bridge_cli, :bridge_packet, :meshtastic] do
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

  @doc "All Meshtastic companion ports (env pin first, then every detected radio)."
  def resolve_ports(:meshtastic, opts \\ []) do
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

  @doc "Re-scan serial ports and notify link processes to reconnect."
  def refresh(name \\ __MODULE__) do
    case safe_call(name, :refresh, {:error, :not_started}, 15_000) do
      {:ok, roles} ->
        notify_reconnect()
        {:ok, roles}

      other ->
        other
    end
  end

  @doc """
  Pure scan used by the GenServer and by tests.

  Options:
  - `:enumerate` — `fn -> %{name => meta}` (default Circuits.UART.enumerate/0)
  - `:probe` — `fn path, meta -> :companion | :bridge_cli | :meshtastic | :unknown | {:error, term}`
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
      Enum.reduce(ports, {%{meshtastic_ports: []}, MapSet.new()}, fn port, {acc, claimed} ->
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

                {Map.put(acc, :companion, %{path: port.path, source: :detected, detail: port}),
                 MapSet.put(claimed, port.path)}

              :bridge_cli ->
                Logger.info("MeshCore discover: #{port.path} -> bridge_cli")

                {Map.put(acc, :bridge_cli, %{path: port.path, source: :detected, detail: port}),
                 MapSet.put(claimed, port.path)}

              :meshtastic ->
                Logger.info("MeshCore discover: #{port.path} -> meshtastic")
                entry = %{path: port.path, source: :detected, detail: port}
                {add_meshtastic(acc, entry), MapSet.put(claimed, port.path)}

              other ->
                Logger.debug("MeshCore discover: #{port.path} -> #{inspect(other)}")
                {acc, claimed}
            end
        end
      end)

    roles =
      %{}
      |> put_role(:companion, env_companion, detected[:companion], :env)
      |> put_role(:bridge_cli, env_cli, detected[:bridge_cli], :env)
      |> put_role(:meshtastic, env_meshtastic, detected[:meshtastic], :env)
      |> maybe_packet(env_packet, detected[:bridge_cli], by_path, claimed)

    Map.put(
      roles,
      :meshtastic_ports,
      merge_meshtastic_ports(detected[:meshtastic_ports], roles[:meshtastic])
    )
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
    roles = scan(state.opts)
    publish(state, roles)
    Logger.info("MeshCore discover refresh: #{format_roles(roles)}")
    {:reply, {:ok, roles}, %{state | roles: roles}}
  end

  defp put_role(roles, role, env_path, detected, :env) when is_binary(env_path) do
    Map.put(roles, role, %{path: env_path, source: :env, detail: detected && detected.detail})
  end

  defp put_role(roles, _role, _env, nil, _), do: roles

  defp put_role(roles, role, _env, detected, _), do: Map.put(roles, role, detected)

  defp maybe_packet(roles, env_packet, _cli, _by_path, _claimed) when is_binary(env_packet) do
    Map.put(roles, :bridge_packet, %{path: env_packet, source: :env, detail: nil})
  end

  defp maybe_packet(roles, _env, %{path: cli_path, detail: detail}, by_path, claimed) do
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

  defp maybe_packet(roles, _, _, _, _), do: roles

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

  defp acm_like?(path) do
    String.contains?(path, "ttyACM") or String.contains?(path, "usbmodem")
  end

  defp next_acm_sibling(path) do
    case Regex.run(~r/^(.*ttyACM)(\d+)$/, path) do
      [_, prefix, num] ->
        prefix <> Integer.to_string(String.to_integer(num) + 1)

      _ ->
        nil
    end
  end

  defp default_probe(path, _meta) do
    Application.ensure_all_started(:circuits_uart)
    Process.flag(:trap_exit, true)

    case Circuits.UART.start_link() do
      {:ok, uart} ->
        result =
          case open_with_timeout(uart, path, @open_timeout_ms) do
            :ok ->
              classify_port(uart)

            {:error, reason} ->
              Logger.debug("MeshCore discover: open #{path} failed: #{inspect(reason)}")
              :unknown
          end

        Process.exit(uart, :kill)

        receive do
          {:EXIT, ^uart, _} -> :ok
        after
          200 -> :ok
        end

        result

      {:error, _} ->
        :unknown
    end
  rescue
    _ -> :unknown
  catch
    :exit, _ -> :unknown
  end

  defp open_with_timeout(uart, path, ms) do
    parent = self()
    ref = make_ref()

    opener =
      spawn(fn ->
        result =
          try do
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

  defp classify_port(uart) do
    _ = Circuits.UART.flush(uart)

    # Companion first — framed query. A CLI port will not answer with `>` frames.
    companion_frame = Protocol.encode_usb_frame(Protocol.device_query_frame())
    _ = Circuits.UART.write(uart, companion_frame)

    case read_until(uart, &companion_response?/1, @probe_timeout_ms) do
      true ->
        :companion

      false ->
        _ = Circuits.UART.flush(uart)
        _ = Circuits.UART.write(uart, "ver\r")

        if read_until(uart, &cli_response?/1, @probe_timeout_ms) do
          :bridge_cli
        else
          _ = Circuits.UART.flush(uart)
          nonce = :rand.uniform(0x7FFF_FFFE) + 1
          _ = Circuits.UART.write(uart, MeshtasticProtocol.want_config_frame(nonce))

          if read_until(uart, &meshtastic_response?/1, @probe_timeout_ms) do
            :meshtastic
          else
            :unknown
          end
        end
    end
  end

  defp companion_response?(data) when is_binary(data) do
    # Require a decoded companion frame. Do NOT treat a bare ">" as success —
    # MeshCore CLI replies use "->" and would false-positive as companions.
    {frames, _} = Protocol.decode_usb_stream(data)

    Enum.any?(frames, fn frame ->
      case Protocol.parse_frame(frame) do
        {:device_info, _} -> true
        {:self_info, _} -> true
        _ -> false
      end
    end)
  end

  defp companion_response?(_), do: false

  defp cli_response?(data) when is_binary(data) do
    down = String.downcase(data)

    String.contains?(down, "v1.") or
      String.contains?(down, "build:") or
      String.contains?(down, "firmware") or
      (String.contains?(down, "->") and String.contains?(down, "v"))
  end

  defp cli_response?(_), do: false

  defp meshtastic_response?(data) when is_binary(data) do
    {frames, _} = MeshtasticProtocol.decode_stream(data)

    Enum.any?(frames, fn payload ->
      case MeshtasticProtocol.parse_frame(payload) do
        {:my_info, _} -> true
        {:node_info, _} -> true
        {:channel, _} -> true
        {:config, _} -> true
        {:config_complete, _} -> true
        {:packet, _} -> true
        :rebooted -> true
        _ -> false
      end
    end)
  end

  defp meshtastic_response?(_), do: false

  defp read_until(uart, pred, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_read_until(uart, pred, deadline, <<>>)
  end

  defp do_read_until(uart, pred, deadline, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      pred.(acc)
    else
      chunk =
        case Circuits.UART.read(uart, min(remaining, 200)) do
          {:ok, data} when is_binary(data) -> data
          _ -> <<>>
        end

      acc = acc <> chunk

      if chunk != "" and pred.(acc) do
        true
      else
        if chunk == "", do: Process.sleep(40)
        do_read_until(uart, pred, deadline, acc)
      end
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
        {:meshtastic_ports, list} when is_list(list) ->
          Enum.map(list, fn
            %{path: path, source: source} -> "meshtastic=#{path}(#{source})"
            _ -> nil
          end)
          |> Enum.reject(&is_nil/1)

        {role, %{path: path, source: source}} ->
          ["#{role}=#{path}(#{source})"]

        _ ->
          []
      end)

    if formatted == [], do: "(none)", else: Enum.join(formatted, " ")
  end

  defp add_meshtastic(acc, entry) do
    acc
    |> Map.update(:meshtastic_ports, [entry], fn list ->
      if Enum.any?(list, &(&1.path == entry.path)), do: list, else: list ++ [entry]
    end)
    |> Map.put_new(:meshtastic, entry)
  end

  defp merge_meshtastic_ports(detected, primary) do
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
