defmodule Isthmus.Networks.MeshCore.BridgeCLI do
  @moduledoc """
  Text CLI link to a bridge-enabled MeshCore repeater (CDC 0).

  Distinct from `BridgeLink`, which speaks the `0xC03E` packet stream on CDC 1.
  Radio configuration (`set radio`, `set tx`, `reboot`) goes through this module.

  Port comes from auto-detect (`Discover`) or `ISTHMUS_MESHCORE_BRIDGE_CLI_PORT`.
  """
  use GenServer

  require Logger

  alias Isthmus.Networks.MeshCore.Discover
  alias Isthmus.Networks.MeshCore.RadioParams
  alias Isthmus.Networks.MeshCore.USBTransport

  @status_table :isthmus_meshcore_bridge_cli_status
  @cmd_timeout_ms 4_000
  @reboot_settle_ms 8_000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def health(name \\ __MODULE__) do
    with table when table != :undefined <- :ets.whereis(@status_table),
         [{{:health, ^name}, health}] <- :ets.lookup(table, {:health, name}) do
      health
    else
      _ ->
        safe_call(name, :health, %{status: :unknown, last_error: "bridge CLI not started"}, 500)
    end
  end

  def configured?(name \\ __MODULE__), do: health(name)[:status] != :disabled

  def get_radio(name \\ __MODULE__) do
    safe_call(name, :get_radio, {:error, :not_started}, @cmd_timeout_ms + 1_000)
  end

  def set_radio(name \\ __MODULE__, params)

  def set_radio(name, params) when is_map(params) do
    with {:ok, normalized} <- RadioParams.cast(params) do
      safe_call(name, {:set_radio, normalized}, {:error, :not_started}, @cmd_timeout_ms + 1_000)
    end
  end

  def set_tx(name \\ __MODULE__, tx)

  def set_tx(name, tx) when is_integer(tx) and tx in 0..22 do
    safe_call(name, {:set_tx, tx}, {:error, :not_started}, @cmd_timeout_ms + 1_000)
  end

  def set_tx(_name, tx) when is_integer(tx), do: {:error, "TX power must be 0–22 dBm"}

  @doc """
  Permanently apply radio + TX, then reboot the repeater.

  After reboot, triggers `Discover.refresh/0` so packet/CLI ports reattach.
  """
  def apply_and_reboot(name \\ __MODULE__, params) when is_map(params) do
    with {:ok, normalized} <- RadioParams.cast(params) do
      safe_call(
        name,
        {:apply_and_reboot, normalized},
        {:error, :not_started},
        @cmd_timeout_ms * 3 + @reboot_settle_ms + 5_000
      )
    end
  end

  def reboot(name \\ __MODULE__) do
    safe_call(name, :reboot, {:error, :not_started}, @cmd_timeout_ms + @reboot_settle_ms)
  end

  def reconnect(name \\ __MODULE__), do: GenServer.cast(name, :reconnect)

  @doc """
  Close an island CLI that never answered `get radio`.

  Kept for tests and a manual release. Discover.refresh/0 no longer calls this:
  a silent `get radio` is not proof the port is Meshtastic.
  """
  def disconnect_unidentified(name \\ __MODULE__) do
    if unidentified_bridge?(health(name)) do
      _ = safe_call(name, :disconnect, :ok, 2_000)

      try do
        Isthmus.Networks.MeshCore.BridgeLink.disconnect()
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  defp unidentified_bridge?(health) when is_map(health) do
    health[:status] in [:online, :live, :running] and is_nil(health[:freq_mhz])
  end

  defp unidentified_bridge?(_), do: false

  defp safe_call(name, request, fallback, timeout) do
    GenServer.call(name, request, timeout)
  catch
    :exit, _ -> fallback
  end

  @impl true
  def init(opts) do
    ensure_ets(@status_table)

    port =
      Keyword.get(opts, :port) || Discover.resolve_port(:bridge_cli)

    state = %{
      name: Keyword.get(opts, :name, __MODULE__),
      transport_mod: Keyword.get(opts, :transport_mod, USBTransport),
      transport: nil,
      port: port,
      transport_opts: Keyword.get(opts, :transport_opts, %{}),
      buffer: <<>>,
      status: :disconnected,
      last_error: nil,
      fail_count: 0,
      radio: nil,
      last_reply: nil,
      firmware_version: nil
    }

    {:ok, maybe_connect(state)}
  end

  @impl true
  def handle_call(:health, _from, state) do
    {:reply, health_map(state), publish_status(state)}
  end

  def handle_call(:get_radio, _from, %{status: :online} = state) do
    {reply, state} = do_get_radio(state)
    {:reply, reply, publish_status(state)}
  end

  def handle_call(:get_radio, _from, state), do: {:reply, {:error, :not_connected}, state}

  def handle_call({:set_radio, params}, _from, %{status: :online} = state) do
    {reply, state} = cli_command(state, RadioParams.cli_radio_command(params))
    {:reply, reply, publish_status(state)}
  end

  def handle_call({:set_radio, _}, _from, state), do: {:reply, {:error, :not_connected}, state}

  def handle_call({:set_tx, tx}, _from, %{status: :online} = state) do
    {reply, state} = cli_command(state, RadioParams.cli_tx_command(%{tx_power: tx}))
    {:reply, reply, publish_status(state)}
  end

  def handle_call({:set_tx, _}, _from, state), do: {:reply, {:error, :not_connected}, state}

  def handle_call({:apply_and_reboot, params}, _from, %{status: :online} = state) do
    with {:ok, state} <- ok_step(cli_command(state, RadioParams.cli_radio_command(params))),
         {:ok, state} <- ok_step(cli_command(state, RadioParams.cli_tx_command(params))),
         {:ok, state} <- ok_step(cli_command(state, "reboot")) do
      Process.send_after(self(), :post_reboot, @reboot_settle_ms)
      {:reply, :ok, publish_status(%{state | status: :rebooting, last_error: nil})}
    else
      {:error, reason, state} ->
        {:reply, {:error, reason}, publish_status(state)}
    end
  end

  def handle_call({:apply_and_reboot, _}, _from, state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call(:reboot, _from, %{status: :online} = state) do
    case cli_command(state, "reboot") do
      {:ok, state} ->
        Process.send_after(self(), :post_reboot, @reboot_settle_ms)
        {:reply, :ok, publish_status(%{state | status: :rebooting})}

      {:error, reason, state} ->
        {:reply, {:error, reason}, publish_status(state)}
    end
  end

  def handle_call(:reboot, _from, state), do: {:reply, {:error, :not_connected}, state}

  def handle_call(:disconnect, _from, state) do
    if state.transport, do: state.transport_mod.close(state.transport)

    {:reply, :ok,
     publish_status(%{
       state
       | transport: nil,
         buffer: <<>>,
         radio: nil,
         last_reply: nil,
         status: :disconnected,
         last_error: "released for rediscovery"
     })}
  end

  @impl true
  def handle_cast(:reconnect, state) do
    if stay_connected?(state) do
      {:noreply, state}
    else
      if state.transport, do: state.transport_mod.close(state.transport)

      state = %{
        state
        | transport: nil,
          buffer: <<>>,
          status: :disconnected,
          port: Discover.resolve_port(:bridge_cli)
      }

      {:noreply, maybe_connect(state)}
    end
  end

  defp stay_connected?(state) do
    state[:status] == :online and not is_nil(state[:transport]) and
      Discover.resolve_port(:bridge_cli) == state[:port]
  end

  @impl true
  def handle_info({:circuits_uart, _port, data}, state) when is_binary(data) do
    {:noreply, %{state | buffer: state.buffer <> data}}
  end

  def handle_info({:circuits_uart, _port, {:error, reason}}, state) do
    Logger.warning("meshcore bridge CLI serial error: #{inspect(reason)}")
    if state.transport, do: state.transport_mod.close(state.transport)
    Process.send_after(self(), :reconnect, 5_000)

    {:noreply,
     publish_status(%{
       state
       | transport: nil,
         buffer: <<>>,
         status: :error,
         last_error: inspect(reason)
     })}
  end

  def handle_info(:reconnect, state) do
    if state.transport, do: state.transport_mod.close(state.transport)

    state = %{
      state
      | transport: nil,
        buffer: <<>>,
        port: Discover.resolve_port(:bridge_cli),
        status: :disconnected
    }

    {:noreply, maybe_connect(state)}
  end

  def handle_info(:post_reboot, state) do
    _ = Discover.refresh()
    if state.transport, do: state.transport_mod.close(state.transport)

    state = %{
      state
      | transport: nil,
        buffer: <<>>,
        port: Discover.resolve_port(:bridge_cli),
        status: :disconnected
    }

    {:noreply, maybe_connect(state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp maybe_connect(%{port: port} = state) when port in [nil, ""] do
    publish_status(%{
      state
      | status: :disabled,
        last_error: "no bridge CLI detected (set ISTHMUS_MESHCORE_BRIDGE_CLI_PORT to override)"
    })
  end

  defp maybe_connect(state) do
    case state.transport_mod.connect(Map.put(state.transport_opts, :port, state.port)) do
      {:ok, transport} ->
        Logger.info("MeshCore bridge CLI online via #{state.port}")

        state =
          publish_status(%{
            state
            | transport: transport,
              status: :online,
              last_error: nil,
              fail_count: 0,
              buffer: <<>>
          })

        state = wake_cli(state)
        {_reply, state} = do_get_radio(state)
        publish_status(state)

      {:error, reason} ->
        delay = min(120_000, 5_000 * max(1, state.fail_count + 1))
        Logger.warning("MeshCore bridge CLI connect failed: #{inspect(reason)}")
        Process.send_after(self(), :reconnect, delay)

        publish_status(%{
          state
          | status: :error,
            last_error: inspect(reason),
            fail_count: state.fail_count + 1
        })
    end
  end

  defp wake_cli(%{transport: nil} = state), do: state

  defp wake_cli(state) do
    _ = state.transport_mod.write(state.transport, "\r")
    drain_uart(state, 200)
  end

  defp drain_uart(state, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_drain_uart(state, deadline)
  end

  defp do_drain_uart(state, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      %{state | buffer: <<>>}
    else
      receive do
        {:circuits_uart, _port, data} when is_binary(data) ->
          do_drain_uart(state, deadline)

        {:circuits_uart, _port, {:error, _}} ->
          %{state | buffer: <<>>}
      after
        min(remaining, 50) ->
          do_drain_uart(state, deadline)
      end
    end
  end

  defp do_get_radio(state) do
    case cli_command(state, "get radio") do
      {:ok, state} ->
        finish_get_radio(state)

      {:error, _reason, state} ->
        case cli_command(state, "get radio") do
          {:ok, state} -> finish_get_radio(state)
          {:error, reason, state} -> {{:error, reason}, state}
        end
    end
  end

  defp finish_get_radio(state) do
    radio = parse_radio_reply(state.last_reply)

    case cli_command(state, "get tx") do
      {:ok, state} ->
        tx = parse_tx_reply(state.last_reply)
        radio = if radio, do: Map.put(radio, :tx_power, tx || radio[:tx_power]), else: radio
        {state, version} = maybe_ver(state)

        {{:ok, radio},
         %{state | radio: radio, firmware_version: version || state.firmware_version}}

      {:error, reason, state} ->
        {{:error, reason}, %{state | radio: radio}}
    end
  end

  defp maybe_ver(state) do
    case cli_command(state, "ver") do
      {:ok, state} -> {state, parse_ver_reply(state.last_reply)}
      {:error, _, state} -> {state, nil}
    end
  end

  defp parse_ver_reply(reply) when is_binary(reply) do
    case Regex.run(~r/v?(\d+\.\d+(?:\.\d+)?)/, reply) do
      [_, ver] -> ver
      _ -> nil
    end
  end

  defp cli_command(%{transport: nil} = state, _cmd), do: {:error, :not_connected, state}

  defp cli_command(state, cmd) when is_binary(cmd) do
    # Drain stale bytes so we don't confuse the previous reply with this one.
    state = %{state | buffer: <<>>, last_reply: nil}
    payload = cmd <> "\r"

    case state.transport_mod.write(state.transport, payload) do
      :ok ->
        case await_reply(state, @cmd_timeout_ms) do
          {:ok, reply, state} ->
            if cli_error?(reply) do
              {:error, String.trim(reply), %{state | last_reply: reply, last_error: reply}}
            else
              {:ok, %{state | last_reply: reply, last_error: nil}}
            end

          {:error, reason, state} ->
            {:error, reason, state}
        end

      {:error, reason} ->
        {:error, reason, %{state | last_error: inspect(reason)}}
    end
  end

  defp await_reply(state, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_reply(state, deadline)
  end

  defp do_await_reply(state, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      if String.trim(state.buffer) != "" do
        {:ok, state.buffer, %{state | buffer: <<>>}}
      else
        {:error, :timeout, state}
      end
    else
      receive do
        {:circuits_uart, _port, data} when is_binary(data) ->
          buffer = state.buffer <> data

          if reply_complete?(buffer) do
            {:ok, buffer, %{state | buffer: <<>>}}
          else
            do_await_reply(%{state | buffer: buffer}, deadline)
          end

        {:circuits_uart, _port, {:error, reason}} ->
          {:error, reason, state}
      after
        min(remaining, 200) ->
          if reply_complete?(state.buffer) do
            {:ok, state.buffer, %{state | buffer: <<>>}}
          else
            do_await_reply(state, deadline)
          end
      end
    end
  end

  defp reply_complete?(buffer) do
    String.contains?(buffer, "\n") or String.contains?(buffer, "->") or
      String.contains?(buffer, "> ")
  end

  defp cli_error?(reply) do
    String.contains?(reply, "??:") or String.contains?(String.downcase(reply), "error")
  end

  defp ok_step({:ok, state}), do: {:ok, state}
  defp ok_step({:error, reason, state}), do: {:error, reason, state}

  @doc false
  def parse_radio_reply(reply) when is_binary(reply) do
    case Regex.run(~r/>\s*([0-9.]+)\s*,\s*([0-9.]+)\s*,\s*(\d+)\s*,\s*(\d+)/, reply) do
      [_, freq, bw, sf, cr] ->
        %{
          freq_mhz: String.to_float(freq),
          bw_khz: String.to_float(bw),
          sf: String.to_integer(sf),
          cr: String.to_integer(cr)
        }

      _ ->
        nil
    end
  end

  def parse_radio_reply(_), do: nil

  @doc false
  def parse_tx_reply(reply) when is_binary(reply) do
    case Regex.run(~r/>\s*(-?\d+)/, reply) do
      [_, tx] -> String.to_integer(tx)
      _ -> nil
    end
  end

  def parse_tx_reply(_), do: nil

  defp health_map(state) do
    radio = state.radio || %{}

    %{
      status: state.status,
      port: state.port,
      last_error: state.last_error,
      last_reply: state.last_reply,
      freq_mhz: radio[:freq_mhz],
      bw_khz: radio[:bw_khz],
      sf: radio[:sf],
      cr: radio[:cr],
      tx_power: radio[:tx_power],
      firmware_version: state.firmware_version
    }
  end

  defp publish_status(state) do
    health = health_map(state)
    :ets.insert(@status_table, {{:health, state.name}, health})
    key = {health[:status], health[:port]}

    if state[:pub_key] != key do
      broadcast_status(:bridge_cli, health)
    end

    Map.put(state, :pub_key, key)
  end

  defp broadcast_status(kind, health) do
    Phoenix.PubSub.broadcast(
      Isthmus.PubSub,
      "meshcore:status",
      {:meshcore_status, kind, health}
    )
  catch
    :error, _ -> :ok
    :exit, _ -> :ok
  end

  defp ensure_ets(name) do
    case :ets.whereis(name) do
      :undefined -> :ets.new(name, [:named_table, :public, :set, read_concurrency: true])
      _ -> name
    end
  end
end
