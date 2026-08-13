defmodule Isthmus.Networks.Meshtastic.Companion do
  @moduledoc """
  Meshtastic companion client over the serial protobuf API.

  The named process owns the primary port (`ISTHMUS_MESHTASTIC_PORT` or the first
  detected radio). Extra USB companions are started via `Meshtastic.Supervisor`
  and addressed by port. Baud 115200. MeshCore companions are classified first
  (framed `<`/`>`), so a Meshtastic radio is only claimed when it answers
  `want_config` with `0x94 0xC3` FromRadio frames.

  Channel slots 0–7 on the radio can be linked to Isthmus bridge groups.
  Inbound TEXT_MESSAGE_APP broadcasts publish on `"meshtastic:inbound"`.
  """
  use GenServer

  require Logger

  alias Isthmus.Networks.MeshCore.Discover
  alias Isthmus.Networks.Meshtastic.Companion.Admin
  alias Isthmus.Networks.Meshtastic.Companion.Inbound
  alias Isthmus.Networks.Meshtastic.Companion.Status
  alias Isthmus.Networks.Meshtastic.DeviceConfig
  alias Isthmus.Networks.Meshtastic.Protocol
  alias Isthmus.Networks.Meshtastic.RadioConfig
  alias Isthmus.Networks.Meshtastic.Settings

  @channels_table :isthmus_meshtastic_channels
  @status_table :isthmus_meshtastic_status
  @registry Isthmus.Networks.Meshtastic.Registry
  @heartbeat_ms 30_000
  @reconnect_ms 5_000
  @baud 115_200

  @type port_arg :: String.t() | nil | :primary
  @type health :: map()
  @type channel :: map()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec via(String.t()) :: {:via, module(), {module(), String.t()}}
  def via(port) when is_binary(port) do
    {:via, Registry, {@registry, port}}
  end

  @spec health() :: health()
  @spec health(port_arg()) :: health()
  def health(port \\ nil) do
    key = Status.ets_port_key(port)

    case :ets.lookup(@status_table, {:health, key}) do
      [{_, health}] ->
        Status.with_estimated_clock(health)

      _ ->
        safe_call(port, :health, %{status: :unknown, last_error: "companion not ready"}, 500)
    end
  end

  @doc "Health maps for every companion process (primary + extras)."
  @spec list_health() :: [health()]
  def list_health do
    @status_table
    |> :ets.match({{:health, :_}, :"$1"})
    |> List.flatten()
    |> Enum.filter(&is_map/1)
    |> Enum.map(&Status.with_estimated_clock/1)
    |> Enum.sort_by(&{if(&1[:primary?], do: 0, else: 1), &1[:port] || ""})
  rescue
    _ ->
      [health()]
  end

  @doc "Serial port owned by the companion with this node id, if any."
  def port_for_radio_id(nil), do: nil

  def port_for_radio_id(id) when is_binary(id) do
    want = id |> String.trim() |> String.trim_leading("!") |> String.downcase()

    list_health()
    |> Enum.find_value(fn health ->
      have =
        case health[:node_id] do
          node when is_binary(node) ->
            node |> String.trim_leading("!") |> String.downcase()

          _ ->
            nil
        end

      if have == want and is_binary(health[:port]) and health[:port] != "", do: health[:port]
    end)
  end

  @doc "Non-blocking read of cached channel slots (ETS)."
  @spec list_channels() :: [channel()]
  @spec list_channels(port_arg()) :: [channel()]
  def list_channels(port \\ nil) do
    key = Status.ets_port_key(port)

    case :ets.lookup(@channels_table, {:all, key}) do
      [{_, channels}] when is_list(channels) and channels != [] ->
        channels

      _ ->
        Enum.map(0..(Status.max_channel_slots() - 1), &Status.empty_channel/1)
    end
  end

  @spec get_channel(integer()) :: channel() | nil
  @spec get_channel(integer(), port_arg()) :: channel() | nil
  def get_channel(idx, port \\ nil) when is_integer(idx) do
    case :ets.lookup(@channels_table, {idx, Status.ets_port_key(port)}) do
      [{_, channel}] -> channel
      _ -> nil
    end
  end

  @doc "Cached LoRa config from the last want_config dump."
  def lora_config(port \\ nil) do
    key = Status.ets_port_key(port)

    case :ets.lookup(@status_table, {:lora, key}) do
      [{_, config}] when is_map(config) -> config
      _ -> RadioConfig.empty()
    end
  end

  @doc "Cached DeviceConfig from the last want_config dump."
  def device_config(port \\ nil) do
    key = Status.ets_port_key(port)

    case :ets.lookup(@status_table, {:device, key}) do
      [{_, config}] when is_map(config) -> config
      _ -> DeviceConfig.empty()
    end
  end

  def sync_channels(port \\ nil), do: GenServer.cast(target(port), :sync_channels)
  def sync_channels_async(port \\ nil), do: GenServer.cast(target(port), :sync_channels)

  def set_channel(idx, name, psk \\ nil, port \\ nil)
      when is_integer(idx) and is_binary(name) do
    safe_call(port, {:set_channel, idx, name, psk}, {:error, :timeout}, 8_000)
  end

  @doc "Disable a secondary slot on the radio (empty name / PSK, role DISABLED)."
  def clear_channel(idx, port \\ nil) when is_integer(idx) and idx in 1..7 do
    safe_call(port, {:clear_channel, idx}, {:error, :timeout}, 8_000)
  end

  def set_lora_config(params, port \\ nil) when is_map(params) do
    safe_call(port, {:set_lora_config, params}, {:error, :timeout}, 8_000)
  end

  @doc """
  Write one or more companion setting sections (`lora`, `device`, …) then reboot.

  `params` is the admin form map (`%{"lora" => …, "device" => …}`) or a
  `Settings.cast/2` result. Omitted sections are left unchanged.
  """
  def set_settings(params, port \\ nil) when is_map(params) do
    safe_call(port, {:set_settings, params}, {:error, :timeout}, 12_000)
  end

  @doc """
  Write host Unix time to the radio (`AdminMessage.set_time_only`) and set
  `DeviceConfig.tzdef` so the OLED shows local time.

  `opts` may include `:tz` (IANA name or POSIX string). Defaults to the host
  timezone (`ISTHMUS_MESHTASTIC_TZ`, `TZ`, or `/etc/localtime`).
  """
  def set_time(port \\ nil, opts \\ [])

  def set_time(port, opts) when is_list(opts) do
    safe_call(port, {:set_time, Keyword.get(opts, :tz)}, {:error, :timeout}, 8_000)
  end

  def send_channel_text(idx, text, port \\ nil)
      when is_integer(idx) and is_binary(text) do
    safe_call(port, {:send_channel_text, idx, text}, {:error, :timeout}, 3_000)
  end

  def send_text(node_ref, text, port \\ nil)
      when is_binary(node_ref) and is_binary(text) do
    safe_call(port, {:send_text, node_ref, text}, {:error, :timeout}, 3_000)
  end

  def reconnect(port \\ nil), do: GenServer.cast(target(port), :reconnect)

  @doc "Inject a decoded inbound event (tests / future radio client)."
  def inject_inbound(kind, attrs) when kind in [:channel, :dm, :nodeinfo] and is_map(attrs) do
    GenServer.cast(__MODULE__, {:inject, kind, attrs})
  end

  defp target(nil), do: __MODULE__
  defp target(:primary), do: __MODULE__

  defp target(port) when is_binary(port) do
    primary = Discover.resolve_port(:meshtastic)
    if port == primary, do: __MODULE__, else: via(port)
  end

  defp safe_call(port, request, fallback, timeout) do
    GenServer.call(target(port), request, timeout)
  catch
    :exit, _ -> fallback
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    Status.ensure_ets(@channels_table)
    Status.ensure_ets(@status_table)

    port = Keyword.get(opts, :port) || Discover.resolve_port(:meshtastic)
    fixed_port? = Keyword.get(opts, :fixed_port, false)
    key = if is_binary(port) and port != "", do: port, else: :none

    :ets.insert(@channels_table, {{:all, key}, []})
    :ets.insert(@status_table, {{:lora, key}, RadioConfig.empty()})
    :ets.insert(@status_table, {{:device, key}, DeviceConfig.empty()})

    state = %{
      uart: nil,
      port: port,
      fixed_port: fixed_port?,
      buffer: <<>>,
      status: :disconnected,
      last_error: nil,
      fail_count: 0,
      channels: %{},
      lora: RadioConfig.empty(),
      device: DeviceConfig.empty(),
      my_info: nil,
      config_nonce: nil,
      admin: nil,
      device_time: nil,
      device_time_at: nil,
      time_synced_at: nil,
      device_tzdef: nil,
      sent: 0,
      received: 0
    }

    state = maybe_connect(state)
    Status.publish_status(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:health, _from, state) do
    health = Status.with_estimated_clock(Status.health_map(state))
    Status.publish_status(state)
    {:reply, health, state}
  end

  def handle_call(:list_channels, _from, state) do
    {:reply, Status.cached_channel_list(state), state}
  end

  def handle_call({:get_channel, idx}, _from, state) when is_integer(idx) do
    {:reply, Map.get(state.channels, idx), state}
  end

  def handle_call({:send_channel_text, idx, text}, _from, %{status: :online, uart: uart} = state)
      when not is_nil(uart) do
    frame = Protocol.send_channel_text_frame(idx, text)
    reply_write(uart, frame, state)
  end

  def handle_call({:send_channel_text, _, _}, _from, state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:send_text, node_ref, text}, _from, %{status: :online, uart: uart} = state)
      when not is_nil(uart) do
    case Protocol.parse_node_id(node_ref) do
      {:ok, num} ->
        reply_write(uart, Protocol.send_dm_text_frame(num, text), state)

      :error ->
        {:reply, {:error, :invalid_node_id}, state}
    end
  end

  def handle_call({:send_text, _, _}, _from, state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:set_channel, idx, name, psk}, from, state) do
    psk_bin = Admin.normalize_psk(psk)
    channel = %{index: idx, name: name, psk: psk_bin, role: Protocol.role_secondary()}
    Admin.begin_channel_write(from, state, channel)
  end

  def handle_call({:clear_channel, idx}, from, state) when idx in 1..7 do
    Admin.begin_channel_write(from, state, Status.empty_channel(idx))
  end

  def handle_call({:set_lora_config, params}, from, %{status: :online, uart: uart} = state)
      when not is_nil(uart) do
    cond do
      is_map(state.admin) ->
        {:reply, {:error, :busy}, state}

      true ->
        case {state.my_info, RadioConfig.cast(params, state.lora || RadioConfig.empty())} do
          {%{my_node_num: num}, {:ok, lora}} when is_integer(num) and num > 0 ->
            frame = Protocol.get_config_admin_frame(num, :lora)
            timer = Process.send_after(self(), :admin_timeout, Admin.timeout_ms())

            case Circuits.UART.write(uart, frame) do
              :ok ->
                {:noreply,
                 %{
                   state
                   | admin: %{
                       kind: :set_lora,
                       from: from,
                       timer: timer,
                       lora: lora,
                       node_num: num
                     }
                 }}

              {:error, reason} ->
                Process.cancel_timer(timer)
                {:reply, {:error, reason}, %{state | last_error: inspect(reason)}}
            end

          {_, {:error, reason}} ->
            {:reply, {:error, reason}, state}

          _ ->
            {:reply, {:error, :not_ready}, state}
        end
    end
  end

  def handle_call({:set_lora_config, _}, _from, state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:set_settings, params}, from, %{status: :online, uart: uart} = state)
      when not is_nil(uart) do
    cond do
      is_map(state.admin) ->
        {:reply, {:error, :busy}, state}

      true ->
        bases = %{
          lora: state.lora || RadioConfig.empty(),
          device: state.device || DeviceConfig.empty()
        }

        case {state.my_info, Settings.cast(params, bases)} do
          {%{my_node_num: num}, {:ok, settings}} when is_integer(num) and num > 0 ->
            Admin.begin_settings_write(from, state, num, settings)

          {_, {:error, reason}} ->
            {:reply, {:error, reason}, state}

          _ ->
            {:reply, {:error, :not_ready}, state}
        end
    end
  end

  def handle_call({:set_settings, _}, _from, state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:set_time, tz}, from, state) do
    Admin.begin_time_sync(from, state, tz)
  end

  @impl true
  def handle_cast(:sync_channels, %{status: :online, uart: uart} = state) when not is_nil(uart) do
    {:noreply, Admin.request_config(state)}
  end

  def handle_cast(:sync_channels, state), do: {:noreply, state}

  def handle_cast(:reconnect, state) do
    {:noreply, reconnect_state(state)}
  end

  def handle_cast({:inject, :channel, attrs}, state) do
    Inbound.publish_channel_msg(attrs)
    {:noreply, %{state | received: state.received + 1}}
  end

  def handle_cast({:inject, :dm, attrs}, state) do
    Inbound.publish_dm(attrs)
    {:noreply, %{state | received: state.received + 1}}
  end

  def handle_cast({:inject, :nodeinfo, attrs}, state) do
    Inbound.record_node_sighting(attrs, "nodeinfo")
    {:noreply, %{state | received: state.received + 1}}
  end

  @impl true
  def handle_info({:circuits_uart, _port, {:error, reason}}, state) do
    Logger.warning("Meshtastic companion serial error: #{inspect(reason)}")
    {:noreply, schedule_reconnect(%{state | last_error: inspect(reason), status: :error})}
  end

  def handle_info({:circuits_uart, _port, data}, state) when is_binary(data) do
    {:noreply, Inbound.consume(state, data)}
  end

  def handle_info(:heartbeat, %{status: :online, uart: uart} = state) when not is_nil(uart) do
    _ = Circuits.UART.write(uart, Protocol.heartbeat_frame())
    Process.send_after(self(), :heartbeat, @heartbeat_ms)
    {:noreply, state}
  end

  def handle_info(:heartbeat, state), do: {:noreply, state}

  def handle_info(:reconnect, state) do
    {:noreply, reconnect_state(state)}
  end

  def handle_info(:admin_timeout, %{admin: admin} = state) when is_map(admin) do
    if admin[:from], do: GenServer.reply(admin.from, {:error, :timeout})
    {:noreply, %{state | admin: nil, last_error: "admin timeout"}}
  end

  def handle_info(:admin_timeout, state), do: {:noreply, state}

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Status.drop_ets(state)
    close_uart(state)
    :ok
  end

  defp maybe_connect(%{port: port} = state) when port in [nil, ""] do
    Status.publish_status(%{
      state
      | status: :disabled,
        last_error: "no companion detected (set ISTHMUS_MESHTASTIC_PORT to override)"
    })
  end

  defp maybe_connect(state) do
    case Circuits.UART.start_link() do
      {:ok, uart} ->
        case Circuits.UART.open(uart, state.port,
               speed: @baud,
               active: true,
               rs232_dtr: false,
               rs232_rts: false
             ) do
          :ok ->
            Logger.info("Meshtastic companion online via #{state.port}")
            Process.send_after(self(), :heartbeat, @heartbeat_ms)

            %{state | uart: uart, status: :online, last_error: nil, fail_count: 0, buffer: <<>>}
            |> Admin.request_config()
            |> Status.publish_status()

          {:error, reason} ->
            Process.exit(uart, :normal)
            fail_connect(state, reason)
        end

      {:error, reason} ->
        fail_connect(state, reason)
    end
  end

  defp fail_connect(state, reason) do
    Logger.warning("Meshtastic companion connect failed: #{inspect(reason)}")
    Process.send_after(self(), :reconnect, @reconnect_ms)

    Status.publish_status(%{
      state
      | uart: nil,
        status: :error,
        last_error: inspect(reason),
        fail_count: (state[:fail_count] || 0) + 1
    })
  end

  defp reconnect_state(%{fixed_port: true} = state) do
    close_uart(state)

    %{
      state
      | uart: nil,
        buffer: <<>>,
        admin: nil,
        my_info: nil,
        channels: %{},
        lora: RadioConfig.empty(),
        device: DeviceConfig.empty(),
        device_time: nil,
        device_time_at: nil,
        time_synced_at: nil,
        device_tzdef: nil
    }
    |> maybe_connect()
  end

  defp reconnect_state(state) do
    close_uart(state)
    port = Discover.resolve_port(:meshtastic) || state.port

    %{
      state
      | uart: nil,
        buffer: <<>>,
        port: port,
        admin: nil,
        my_info: nil,
        channels: %{},
        lora: RadioConfig.empty(),
        device: DeviceConfig.empty(),
        device_time: nil,
        device_time_at: nil,
        time_synced_at: nil,
        device_tzdef: nil
    }
    |> maybe_connect()
  end

  defp schedule_reconnect(state) do
    close_uart(state)
    Process.send_after(self(), :reconnect, @reconnect_ms)
    Status.publish_status(%{state | uart: nil, status: :error})
  end

  defp close_uart(%{uart: uart}) when is_pid(uart) do
    _ = Circuits.UART.close(uart)
    Process.exit(uart, :normal)
    :ok
  catch
    _, _ -> :ok
  end

  defp close_uart(_), do: :ok

  defp reply_write(uart, frame, state) do
    case Circuits.UART.write(uart, frame) do
      :ok -> {:reply, :ok, %{state | sent: state.sent + 1}}
      {:error, reason} -> {:reply, {:error, reason}, %{state | last_error: inspect(reason)}}
    end
  end
end
