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

  alias Isthmus.Announce.Inbound
  alias Isthmus.Networks.MeshCore.Discover
  alias Isthmus.Networks.Meshtastic.DeviceConfig
  alias Isthmus.Networks.Meshtastic.Protocol
  alias Isthmus.Networks.Meshtastic.RadioConfig
  alias Isthmus.Networks.Meshtastic.Settings
  alias Isthmus.Networks.Meshtastic.Timezone

  @channels_table :isthmus_meshtastic_channels
  @status_table :isthmus_meshtastic_status
  @registry Isthmus.Networks.Meshtastic.Registry
  @max_channel_slots 8
  @heartbeat_ms 30_000
  @reconnect_ms 5_000
  @admin_timeout_ms 4_000
  @baud 115_200

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def via(port) when is_binary(port) do
    {:via, Registry, {@registry, port}}
  end

  def health(port \\ nil) do
    key = ets_port_key(port)

    case :ets.lookup(@status_table, {:health, key}) do
      [{_, health}] ->
        with_estimated_clock(health)

      _ ->
        safe_call(port, :health, %{status: :unknown, last_error: "companion not ready"}, 500)
    end
  end

  @doc "Health maps for every companion process (primary + extras)."
  def list_health do
    @status_table
    |> :ets.match({{:health, :_}, :"$1"})
    |> List.flatten()
    |> Enum.filter(&is_map/1)
    |> Enum.map(&with_estimated_clock/1)
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
  def list_channels(port \\ nil) do
    key = ets_port_key(port)

    case :ets.lookup(@channels_table, {:all, key}) do
      [{_, channels}] when is_list(channels) and channels != [] ->
        channels

      _ ->
        Enum.map(0..(@max_channel_slots - 1), &empty_channel/1)
    end
  end

  def get_channel(idx, port \\ nil) when is_integer(idx) do
    case :ets.lookup(@channels_table, {idx, ets_port_key(port)}) do
      [{_, channel}] -> channel
      _ -> nil
    end
  end

  @doc "Cached LoRa config from the last want_config dump."
  def lora_config(port \\ nil) do
    key = ets_port_key(port)

    case :ets.lookup(@status_table, {:lora, key}) do
      [{_, config}] when is_map(config) -> config
      _ -> RadioConfig.empty()
    end
  end

  @doc "Cached DeviceConfig from the last want_config dump."
  def device_config(port \\ nil) do
    key = ets_port_key(port)

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

  defp ets_port_key(nil), do: Discover.resolve_port(:meshtastic) || :none
  defp ets_port_key(:primary), do: Discover.resolve_port(:meshtastic) || :none
  defp ets_port_key(port) when is_binary(port) and port != "", do: port
  defp ets_port_key(_), do: :none

  defp safe_call(port, request, fallback, timeout) do
    GenServer.call(target(port), request, timeout)
  catch
    :exit, _ -> fallback
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    ensure_ets(@channels_table)
    ensure_ets(@status_table)

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
    publish_status(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:health, _from, state) do
    health = with_estimated_clock(health_map(state))
    publish_status(state)
    {:reply, health, state}
  end

  def handle_call(:list_channels, _from, state) do
    {:reply, cached_channel_list(state), state}
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
    psk_bin = normalize_psk(psk)
    channel = %{index: idx, name: name, psk: psk_bin, role: Protocol.role_secondary()}
    begin_channel_write(from, state, channel)
  end

  def handle_call({:clear_channel, idx}, from, state) when idx in 1..7 do
    begin_channel_write(from, state, empty_channel(idx))
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
            timer = Process.send_after(self(), :admin_timeout, @admin_timeout_ms)

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
            begin_settings_write(from, state, num, settings)

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
    begin_time_sync(from, state, tz)
  end

  @impl true
  def handle_cast(:sync_channels, %{status: :online, uart: uart} = state) when not is_nil(uart) do
    {:noreply, request_config(state)}
  end

  def handle_cast(:sync_channels, state), do: {:noreply, state}

  def handle_cast(:reconnect, state) do
    {:noreply, reconnect_state(state)}
  end

  def handle_cast({:inject, :channel, attrs}, state) do
    publish_channel_msg(attrs)
    {:noreply, %{state | received: state.received + 1}}
  end

  def handle_cast({:inject, :dm, attrs}, state) do
    publish_dm(attrs)
    {:noreply, %{state | received: state.received + 1}}
  end

  def handle_cast({:inject, :nodeinfo, attrs}, state) do
    record_node_sighting(attrs, "nodeinfo")
    {:noreply, %{state | received: state.received + 1}}
  end

  @impl true
  def handle_info({:circuits_uart, _port, {:error, reason}}, state) do
    Logger.warning("Meshtastic companion serial error: #{inspect(reason)}")
    {:noreply, schedule_reconnect(%{state | last_error: inspect(reason), status: :error})}
  end

  def handle_info({:circuits_uart, _port, data}, state) when is_binary(data) do
    {:noreply, consume(state, data)}
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
    drop_ets(state)
    close_uart(state)
    :ok
  end

  defp consume(state, data) do
    {frames, buffer} = Protocol.decode_stream(state.buffer <> data)

    Enum.reduce(frames, %{state | buffer: buffer}, fn payload, acc ->
      handle_payload(acc, payload)
    end)
  end

  defp handle_payload(state, payload) do
    case Protocol.parse_frame(payload) do
      {:packet, pkt} ->
        handle_packet(%{state | received: state.received + 1}, pkt)

      {:my_info, info} ->
        publish_status(%{state | my_info: info, last_error: nil})

      {:node_info, info} ->
        record_node_sighting(info, "node_db", state)
        note_own_node_time(%{state | received: state.received + 1}, info)

      {:channel, channel} ->
        put_channel(state, channel)

      {:config, {:lora, lora}} ->
        persist_lora(%{state | lora: lora})

      {:config, {:device, device}} ->
        persist_device(%{state | device: device})

      {:config, _} ->
        state

      {:config_complete, nonce} ->
        if state.config_nonce == nonce do
          state
          |> persist_channels()
          |> broadcast_channels()
          |> persist_lora()
          |> broadcast_lora()
          |> maybe_begin_time_sync()
        else
          state
        end

      :rebooted ->
        Logger.info("Meshtastic companion rebooted — re-requesting config")
        request_config(state)

      {:other, _} ->
        state
    end
  end

  defp handle_packet(state, %{portnum: port} = pkt) when port == 6 do
    maybe_handle_admin(state, pkt)
  end

  defp handle_packet(state, %{portnum: port} = pkt) when port == 3 do
    pos = Protocol.parse_position(pkt.payload)
    maybe_note_device_time(state, pkt.from, pos.time)
  end

  defp handle_packet(state, %{portnum: port} = pkt) when port == 67 do
    maybe_note_device_time(state, pkt.from, Protocol.parse_telemetry_time(pkt.payload))
  end

  defp handle_packet(state, %{portnum: port} = pkt) when port == 1 do
    my_num = get_in(state, [:my_info, :my_node_num])

    cond do
      is_integer(my_num) and pkt.from == my_num ->
        state

      pkt.to == Protocol.broadcast() ->
        publish_channel_msg(%{
          channel_idx: pkt.channel,
          body: sanitize_text(pkt.payload),
          from_ref: Protocol.node_id_hex(pkt.from),
          meta: %{
            from: pkt.from,
            id: pkt.id,
            radio_id: get_in(state, [:my_info, :node_id]),
            port: state.port
          }
        })

        state

      is_integer(my_num) and pkt.to == my_num ->
        publish_dm(%{
          from_ref: Protocol.node_id_hex(pkt.from),
          to_ref: Protocol.node_id_hex(pkt.to),
          body: sanitize_text(pkt.payload),
          meta: %{id: pkt.id, channel: pkt.channel}
        })

        state

      true ->
        state
    end
  end

  defp handle_packet(state, %{portnum: port} = pkt) when port == 4 do
    user = Protocol.parse_user(pkt.payload)
    node_id = user.node_id || Protocol.node_id_hex(pkt.from)

    record_node_sighting(
      %{
        num: pkt.from,
        node_id: node_id,
        name: user.name,
        short_name: user.short_name,
        snr: pkt[:snr],
        hops: pkt[:hops]
      },
      "nodeinfo",
      state
    )

    state
  end

  defp handle_packet(state, _), do: state

  defp begin_channel_write(_from, %{admin: admin} = state, _channel) when is_map(admin) do
    {:reply, {:error, :busy}, state}
  end

  defp begin_channel_write(from, %{status: :online, uart: uart} = state, channel)
       when not is_nil(uart) do
    idx = channel[:index]

    case state.my_info do
      %{my_node_num: num} when is_integer(num) and num > 0 and is_integer(idx) ->
        frame = Protocol.get_channel_admin_frame(num, idx)
        timer = Process.send_after(self(), :admin_timeout, @admin_timeout_ms)

        case Circuits.UART.write(uart, frame) do
          :ok ->
            {:noreply,
             %{
               state
               | admin: %{
                   kind: :set_channel,
                   from: from,
                   timer: timer,
                   channel: channel,
                   node_num: num
                 }
             }}

          {:error, reason} ->
            Process.cancel_timer(timer)
            {:reply, {:error, reason}, %{state | last_error: inspect(reason)}}
        end

      _ ->
        {:reply, {:error, :not_ready}, state}
    end
  end

  defp begin_channel_write(_from, state, _channel) do
    {:reply, {:error, :not_connected}, state}
  end

  defp maybe_handle_admin(%{admin: %{kind: :set_channel} = admin} = state, pkt) do
    case Protocol.parse_admin_payload(pkt.payload) do
      {:get_channel_response, _ch, passkey} ->
        if is_reference(admin.timer), do: Process.cancel_timer(admin.timer)

        frame = Protocol.set_channel_admin_frame(admin.node_num, admin.channel, passkey)

        case Circuits.UART.write(state.uart, frame) do
          :ok ->
            channel = channel_map(admin.channel)
            state = put_channel(state, channel) |> persist_channels()
            GenServer.reply(admin.from, {:ok, channel})
            request_config(%{state | admin: nil, sent: state.sent + 1})

          {:error, reason} ->
            GenServer.reply(admin.from, {:error, reason})
            %{state | admin: nil, last_error: inspect(reason)}
        end

      _ ->
        state
    end
  end

  defp maybe_handle_admin(%{admin: %{kind: :set_lora} = admin} = state, pkt) do
    case Protocol.parse_admin_payload(pkt.payload) do
      {:get_config_response, _cfg, passkey} ->
        if is_reference(admin.timer), do: Process.cancel_timer(admin.timer)

        frame = Protocol.set_config_lora_admin_frame(admin.node_num, admin.lora, passkey)

        case Circuits.UART.write(state.uart, frame) do
          :ok ->
            _ = Circuits.UART.write(state.uart, Protocol.reboot_admin_frame(admin.node_num, 2))
            state = persist_lora(%{state | lora: admin.lora, sent: state.sent + 1})
            broadcast_lora(state)
            GenServer.reply(admin.from, {:ok, admin.lora})
            %{state | admin: nil}

          {:error, reason} ->
            GenServer.reply(admin.from, {:error, reason})
            %{state | admin: nil, last_error: inspect(reason)}
        end

      _ ->
        state
    end
  end

  defp maybe_handle_admin(%{admin: %{kind: :set_settings} = admin} = state, pkt) do
    case {admin.step, Protocol.parse_admin_payload(pkt.payload)} do
      {:get_device, {:get_config_response, cfg, passkey}} ->
        apply_device_settings_step(state, admin, cfg, passkey)

      {:get_lora, {:get_config_response, _cfg, passkey}} ->
        apply_lora_settings_step(state, admin, passkey)

      _ ->
        state
    end
  end

  defp maybe_handle_admin(%{admin: %{kind: :set_time} = admin} = state, pkt) do
    case Protocol.parse_admin_payload(pkt.payload) do
      {:get_config_response, cfg, passkey} ->
        if is_reference(admin.timer), do: Process.cancel_timer(admin.timer)

        unix = System.os_time(:second)
        frame = Protocol.set_time_admin_frame(admin.node_num, unix, passkey)

        case Circuits.UART.write(state.uart, frame) do
          :ok ->
            tzdef = apply_device_tzdef(state, admin, cfg, passkey)
            if admin[:from], do: GenServer.reply(admin.from, :ok)

            put_device_time(
              %{state | admin: nil, sent: state.sent + 1, device_tzdef: tzdef},
              unix,
              synced?: true
            )

          {:error, reason} ->
            if admin[:from], do: GenServer.reply(admin.from, {:error, reason})
            %{state | admin: nil, last_error: inspect(reason)}
        end

      _ ->
        state
    end
  end

  defp maybe_handle_admin(state, _), do: state

  defp begin_time_sync(_from, %{admin: admin} = state, _tz) when is_map(admin) do
    {:reply, {:error, :busy}, state}
  end

  defp begin_time_sync(from, %{status: :online, uart: uart} = state, tz) when not is_nil(uart) do
    case state.my_info do
      %{my_node_num: num} when is_integer(num) and num > 0 ->
        frame = Protocol.get_config_admin_frame(num, :device)
        timer = Process.send_after(self(), :admin_timeout, @admin_timeout_ms)

        case Circuits.UART.write(uart, frame) do
          :ok ->
            {:noreply,
             %{
               state
               | admin: %{kind: :set_time, from: from, timer: timer, node_num: num, tz: tz}
             }}

          {:error, reason} ->
            Process.cancel_timer(timer)
            {:reply, {:error, reason}, %{state | last_error: inspect(reason)}}
        end

      _ ->
        {:reply, {:error, :not_ready}, state}
    end
  end

  defp begin_time_sync(_from, state, _tz) do
    {:reply, {:error, :not_connected}, state}
  end

  defp begin_settings_write(from, %{uart: uart} = state, num, settings) do
    {step, type} =
      if settings.device, do: {:get_device, :device}, else: {:get_lora, :lora}

    frame = Protocol.get_config_admin_frame(num, type)
    timer = Process.send_after(self(), :admin_timeout, @admin_timeout_ms)

    case Circuits.UART.write(uart, frame) do
      :ok ->
        {:noreply,
         %{
           state
           | admin: %{
               kind: :set_settings,
               step: step,
               from: from,
               timer: timer,
               node_num: num,
               device: settings.device,
               lora: settings.lora
             }
         }}

      {:error, reason} ->
        Process.cancel_timer(timer)
        {:reply, {:error, reason}, %{state | last_error: inspect(reason)}}
    end
  end

  defp apply_device_settings_step(state, admin, cfg, passkey) do
    if is_reference(admin.timer), do: Process.cancel_timer(admin.timer)

    base =
      case cfg do
        {:device, %{} = device} -> device
        _ -> DeviceConfig.empty()
      end

    device = DeviceConfig.merge(base, admin.device)
    frame = Protocol.set_config_device_admin_frame(admin.node_num, device, passkey)

    case Circuits.UART.write(state.uart, frame) do
      :ok ->
        state =
          persist_device(%{
            state
            | device: device,
              sent: state.sent + 1
          })

        broadcast_device(state)
        admin = %{admin | device: device}

        if admin.lora do
          continue_settings(state, admin, :lora)
        else
          finish_settings(state, admin)
        end

      {:error, reason} ->
        GenServer.reply(admin.from, {:error, reason})
        %{state | admin: nil, last_error: inspect(reason)}
    end
  end

  defp apply_lora_settings_step(state, admin, passkey) do
    if is_reference(admin.timer), do: Process.cancel_timer(admin.timer)

    frame = Protocol.set_config_lora_admin_frame(admin.node_num, admin.lora, passkey)

    case Circuits.UART.write(state.uart, frame) do
      :ok ->
        state = persist_lora(%{state | lora: admin.lora, sent: state.sent + 1})
        broadcast_lora(state)
        finish_settings(state, admin)

      {:error, reason} ->
        GenServer.reply(admin.from, {:error, reason})
        %{state | admin: nil, last_error: inspect(reason)}
    end
  end

  defp continue_settings(state, admin, :lora) do
    timer = Process.send_after(self(), :admin_timeout, @admin_timeout_ms)
    frame = Protocol.get_config_admin_frame(admin.node_num, :lora)

    case Circuits.UART.write(state.uart, frame) do
      :ok ->
        %{state | admin: %{admin | step: :get_lora, timer: timer}}

      {:error, reason} ->
        GenServer.reply(admin.from, {:error, reason})
        %{state | admin: nil, last_error: inspect(reason)}
    end
  end

  defp finish_settings(state, admin) do
    _ = Circuits.UART.write(state.uart, Protocol.reboot_admin_frame(admin.node_num, 2))

    GenServer.reply(admin.from, {:ok, %{device: state.device, lora: state.lora}})
    %{state | admin: nil}
  end

  defp maybe_begin_time_sync(state) do
    case begin_time_sync(nil, state, nil) do
      {:noreply, new_state} -> new_state
      {:reply, _, state} -> state
    end
  end

  defp apply_device_tzdef(state, admin, cfg, passkey) do
    posix = Timezone.posix(admin[:tz])

    device =
      case cfg do
        {:device, %{} = device} -> device
        {:other, _} -> Protocol.empty_device_config()
        _ -> nil
      end

    cond do
      posix == "" ->
        state[:device_tzdef]

      is_nil(device) ->
        state[:device_tzdef]

      device[:tzdef] == posix ->
        posix

      true ->
        frame =
          Protocol.set_config_device_admin_frame(
            admin.node_num,
            Map.put(device, :tzdef, posix),
            passkey
          )

        case Circuits.UART.write(state.uart, frame) do
          :ok -> posix
          {:error, _} -> state[:device_tzdef]
        end
    end
  end

  defp note_own_node_time(state, info) when is_map(info) do
    my_num = get_in(state, [:my_info, :my_node_num])

    unix =
      cond do
        valid_unix?(info[:position_time]) -> info.position_time
        valid_unix?(info[:last_heard]) -> info.last_heard
        true -> 0
      end

    if is_integer(my_num) and info[:num] == my_num do
      maybe_note_device_time(state, my_num, unix)
    else
      state
    end
  end

  defp maybe_note_device_time(state, from, unix) do
    my_num = get_in(state, [:my_info, :my_node_num])

    if valid_unix?(unix) and (is_nil(my_num) or from == my_num) do
      put_device_time(state, unix)
    else
      state
    end
  end

  defp put_device_time(state, unix, opts \\ [])

  defp put_device_time(state, unix, opts) when is_integer(unix) and unix > 1_000_000_000 do
    now = DateTime.utc_now()
    synced? = Keyword.get(opts, :synced?, false)
    synced_at = if synced?, do: now, else: state[:time_synced_at]

    if synced? do
      Logger.info("Meshtastic companion time synced via #{state.port || "unknown port"}")
    end

    publish_status(%{
      state
      | device_time: unix,
        device_time_at: now,
        time_synced_at: synced_at
    })
  end

  defp put_device_time(state, _, _), do: state

  defp valid_unix?(n) when is_integer(n) and n > 1_000_000_000, do: true
  defp valid_unix?(_), do: false

  defp with_estimated_clock(health) when is_map(health) do
    unix = health[:device_time]
    at = health[:device_time_at]

    now =
      cond do
        is_integer(unix) and unix > 0 and match?(%DateTime{}, at) ->
          unix + max(DateTime.diff(DateTime.utc_now(), at, :second), 0)

        is_integer(unix) and unix > 0 ->
          unix

        true ->
          nil
      end

    Map.put(health, :device_time_now, now)
  end

  defp with_estimated_clock(health), do: health

  defp put_channel(state, %{index: idx} = channel) when is_integer(idx) do
    channel = channel_map(channel)
    key = state_ets_key(state)
    :ets.insert(@channels_table, {{idx, key}, channel})
    %{state | channels: Map.put(state.channels, idx, channel)}
  end

  defp persist_channels(state) do
    list = cached_channel_list(state)
    :ets.insert(@channels_table, {{:all, state_ets_key(state)}, list})
    state
  end

  defp persist_lora(state) do
    lora = state.lora || RadioConfig.empty()
    :ets.insert(@status_table, {{:lora, state_ets_key(state)}, lora})
    state
  end

  defp persist_device(state) do
    device = state.device || DeviceConfig.empty()
    :ets.insert(@status_table, {{:device, state_ets_key(state)}, device})
    publish_status(%{state | device_tzdef: device[:tzdef] || state[:device_tzdef]})
  end

  defp broadcast_lora(state) do
    Phoenix.PubSub.broadcast(
      Isthmus.PubSub,
      "meshtastic:lora",
      {:meshtastic_lora, state.lora || RadioConfig.empty(), state.port}
    )

    state
  end

  defp broadcast_device(state) do
    Phoenix.PubSub.broadcast(
      Isthmus.PubSub,
      "meshtastic:device",
      {:meshtastic_device, state.device || DeviceConfig.empty(), state.port}
    )

    state
  end

  defp cached_channel_list(state) do
    Enum.map(0..(@max_channel_slots - 1), fn idx ->
      Map.get(state.channels, idx) || empty_channel(idx)
    end)
  end

  defp empty_channel(idx) do
    %{
      index: idx,
      name: "",
      psk: <<>>,
      psk_hex: "",
      secret_hex: "",
      channel_id: nil,
      role: Protocol.role_disabled(),
      empty?: true
    }
  end

  defp channel_map(ch) do
    psk = ch[:psk] || Protocol.psk_from_hex(ch[:psk_hex] || ch[:secret_hex]) || <<>>
    name = ch[:name] || ""
    role = ch[:role] || Protocol.role_secondary()
    hex = Base.encode16(psk, case: :lower)

    %{
      index: ch[:index] || 0,
      name: name,
      psk: psk,
      psk_hex: hex,
      secret_hex: hex,
      channel_id: ch[:channel_id],
      role: role,
      empty?:
        (ch[:empty?] || role == Protocol.role_disabled()) or (name == "" and psk in [<<>>, <<0>>])
    }
  end

  defp request_config(%{uart: uart} = state) when not is_nil(uart) do
    nonce = :rand.uniform(0x7FFF_FFFE) + 1

    case Circuits.UART.write(uart, Protocol.want_config_frame(nonce)) do
      :ok ->
        %{state | config_nonce: nonce, sent: state.sent + 1}

      {:error, reason} ->
        %{state | last_error: inspect(reason)}
    end
  end

  defp request_config(state), do: state

  defp maybe_connect(%{port: port} = state) when port in [nil, ""] do
    publish_status(%{
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
            |> request_config()
            |> publish_status()

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

    publish_status(%{
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
    publish_status(%{state | uart: nil, status: :error})
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

  defp publish_channel_msg(attrs) do
    Phoenix.PubSub.broadcast(
      Isthmus.PubSub,
      "meshtastic:inbound",
      {:meshtastic_channel,
       %{
         channel_idx: attrs[:channel_idx] || attrs["channel_idx"],
         body: attrs[:body] || attrs["body"] || "",
         from_ref: attrs[:from_ref] || attrs["from_ref"],
         meta: attrs[:meta] || attrs["meta"] || %{}
       }}
    )
  end

  defp publish_dm(attrs) do
    Phoenix.PubSub.broadcast(
      Isthmus.PubSub,
      "meshtastic:inbound",
      {:meshtastic_dm,
       %{
         from_ref: attrs[:from_ref] || attrs["from_ref"],
         to_ref: attrs[:to_ref] || attrs["to_ref"],
         body: attrs[:body] || attrs["body"] || "",
         external_id: attrs[:external_id] || attrs["external_id"],
         meta: attrs[:meta] || attrs["meta"] || %{}
       }}
    )
  end

  defp broadcast_channels(state) do
    Phoenix.PubSub.broadcast(
      Isthmus.PubSub,
      "meshtastic:channels",
      {:meshtastic_channels, cached_channel_list(state), state.port}
    )

    state
  end

  defp health_map(state) do
    lora = state.lora || RadioConfig.empty()
    port = state.port

    %{
      status: state.status,
      port: port,
      id: port || "none",
      primary?: state[:fixed_port] != true,
      transport: :usb,
      detail: "Meshtastic serial companion",
      last_error: state.last_error,
      sent: state.sent,
      received: state.received,
      node_id: get_in(state, [:my_info, :node_id]),
      self_ref: get_in(state, [:my_info, :node_id]),
      my_node_num: get_in(state, [:my_info, :my_node_num]),
      region: lora[:region],
      region_label: RadioConfig.region_label(lora[:region]),
      modem_preset: lora[:modem_preset],
      modem_preset_label: RadioConfig.preset_label(lora[:modem_preset]),
      use_preset: lora[:use_preset],
      hop_limit: lora[:hop_limit],
      tx_power: lora[:tx_power],
      buzzer_mode: (state.device || %{})[:buzzer_mode],
      buzzer_mode_label: DeviceConfig.buzzer_label((state.device || %{})[:buzzer_mode]),
      device_time: state[:device_time],
      device_time_at: state[:device_time_at],
      time_synced_at: state[:time_synced_at],
      tzdef: state[:device_tzdef]
    }
  end

  defp publish_status(state) do
    :ets.insert(@status_table, {{:health, state_ets_key(state)}, health_map(state)})
    state
  end

  defp state_ets_key(%{port: port}) when is_binary(port) and port != "", do: port
  defp state_ets_key(_), do: :none

  defp drop_ets(state) do
    key = state_ets_key(state)
    :ets.delete(@status_table, {:health, key})
    :ets.delete(@status_table, {:lora, key})
    :ets.delete(@status_table, {:device, key})
    :ets.delete(@channels_table, {:all, key})
    :ok
  rescue
    _ -> :ok
  end

  defp record_node_sighting(info, source, state \\ %{}) do
    my_num = get_in(state, [:my_info, :my_node_num])
    num = info[:num] || info["num"]
    node_id = info[:node_id] || info["node_id"]

    node_id =
      cond do
        is_binary(node_id) and node_id != "" ->
          node_id |> String.trim_leading("!") |> String.downcase()

        is_integer(num) and num > 0 ->
          Protocol.node_id_hex(num)

        true ->
          nil
      end

    cond do
      is_nil(node_id) ->
        :ok

      is_integer(my_num) and is_integer(num) and num == my_num ->
        :ok

      true ->
        extra =
          %{}
          |> maybe_put_extra(:hops, info[:hops] || info["hops"])
          |> maybe_put_extra(:snr, info[:snr] || info["snr"])

        Inbound.record_meshtastic(node_id, info[:name] || info["name"], source, extra)
    end
  end

  defp maybe_put_extra(extra, :hops, n) when is_integer(n) and n >= 0,
    do: Map.put(extra, :hops, n)

  defp maybe_put_extra(extra, :snr, n) when is_number(n) and n != 0, do: Map.put(extra, :snr, n)
  defp maybe_put_extra(extra, _key, _value), do: extra

  defp sanitize_text(text) when is_binary(text) do
    if String.valid?(text) do
      String.trim(text)
    else
      ""
    end
  end

  defp sanitize_text(_), do: ""

  defp normalize_psk(nil), do: :crypto.strong_rand_bytes(16)
  defp normalize_psk(<<>>), do: :crypto.strong_rand_bytes(16)

  defp normalize_psk(bin) when is_binary(bin) do
    cond do
      byte_size(bin) in [16, 32] ->
        bin

      String.match?(bin, ~r/^[0-9a-fA-F]+$/) and rem(byte_size(bin), 2) == 0 ->
        Protocol.psk_from_hex(bin) || :crypto.strong_rand_bytes(16)

      true ->
        :crypto.strong_rand_bytes(16)
    end
  end

  defp ensure_ets(name) do
    case :ets.whereis(name) do
      :undefined -> :ets.new(name, [:named_table, :public, :set, read_concurrency: true])
      _ -> name
    end
  end
end
