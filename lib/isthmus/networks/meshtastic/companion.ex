defmodule Isthmus.Networks.Meshtastic.Companion do
  @moduledoc """
  Meshtastic companion client over the serial protobuf API.

  The named process owns the primary USB port (`ISTHMUS_MESHTASTIC_PORT` or the
  first detected radio). Extra USB and BLE companions are started via
  `Meshtastic.Supervisor` and addressed by port (`/dev/…` or `ble:<address>`).

  Pin a BLE radio with `ISTHMUS_MESHTASTIC_BLE_ADDRESS` and optional
  `ISTHMUS_MESHTASTIC_BLE_PIN` (otherwise the admin UI asks after Connect).
  Baud 115200 on USB. MeshCore
  companions and repeater CLIs are classified first, so a Meshtastic radio is
  only claimed when it answers `want_config` with a FromRadio payload (not an
  echo of the ToRadio probe).

  Channel slots 0–7 on the radio can be linked to Isthmus bridge groups.
  Inbound TEXT_MESSAGE_APP broadcasts publish on `"meshtastic:inbound"`.
  """
  use GenServer

  require Logger

  alias Isthmus.Networks.MeshCore.Discover
  alias Isthmus.Networks.Meshtastic.BLETransport
  alias Isthmus.Networks.Meshtastic.Companion.Admin
  alias Isthmus.Networks.Meshtastic.Companion.Inbound
  alias Isthmus.Networks.Meshtastic.Companion.Link
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

  @doc "Registry / ETS key for a BLE companion (`ble:<address>`)."
  def ble_key(address) when is_binary(address) do
    "ble:" <> normalize_ble_address(address)
  end

  def ble_address(key) when is_binary(key), do: normalize_ble_address(key)

  def normalize_ble_address(address) when is_binary(address) do
    address
    |> String.trim()
    |> then(fn
      "ble:" <> rest -> rest
      "BLE:" <> rest -> rest
      other -> other
    end)
    |> String.upcase()
  end

  def same_ble_address?(a, b) when is_binary(a) and is_binary(b) do
    normalize_ble_address(a) == normalize_ble_address(b)
  end

  def same_ble_address?(_, _), do: false

  def ble_link_lost?(reason) do
    text =
      case reason do
        atom when is_atom(atom) -> Atom.to_string(atom)
        bin when is_binary(bin) -> bin
        other -> inspect(other)
      end
      |> String.downcase()

    text in ["not_connected", "disconnected"] or
      String.contains?(text, "not_connected") or
      String.contains?(text, "device disconnected")
  end

  def ble_retryable_error?(reason) do
    ble_transient_error?(reason)
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
  rescue
    _ ->
      Enum.map(0..(Status.max_channel_slots() - 1), &Status.empty_channel/1)
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
    safe_call(
      port,
      {:set_channel, idx, name, psk},
      {:error, :timeout},
      admin_rpc_timeout(port, 8_000)
    )
  end

  @doc "Disable a secondary slot on the radio (empty name / PSK, role DISABLED)."
  def clear_channel(idx, port \\ nil) when is_integer(idx) and idx in 1..7 do
    safe_call(port, {:clear_channel, idx}, {:error, :timeout}, admin_rpc_timeout(port, 8_000))
  end

  def set_lora_config(params, port \\ nil) when is_map(params) do
    safe_call(
      port,
      {:set_lora_config, params},
      {:error, :timeout},
      admin_rpc_timeout(port, 8_000)
    )
  end

  @doc """
  Write one or more companion setting sections (`lora`, `device`, …) then reboot.

  `params` is the admin form map (`%{"lora" => …, "device" => …}`) or a
  `Settings.cast/2` result. Omitted sections are left unchanged.
  """
  def set_settings(params, port \\ nil) when is_map(params) do
    safe_call(port, {:set_settings, params}, {:error, :timeout}, admin_rpc_timeout(port, 12_000))
  end

  @doc """
  Write host Unix time to the radio (`AdminMessage.set_time_only`) and set
  `DeviceConfig.tzdef` so the OLED shows local time.

  `opts` may include `:tz` (IANA name or POSIX string). Defaults to the host
  timezone (`ISTHMUS_MESHTASTIC_TZ`, `TZ`, or `/etc/localtime`).
  """
  def set_time(port \\ nil, opts \\ [])

  def set_time(port, opts) when is_list(opts) do
    safe_call(
      port,
      {:set_time, Keyword.get(opts, :tz)},
      {:error, :timeout},
      admin_rpc_timeout(port, 8_000)
    )
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

  @doc """
  Close UART on companions that came online without a MyNodeInfo handshake.

  Discovery used to treat a MeshCore repeater's echo of `want_config` as
  Meshtastic, then skip that port on Rescan because the UART was already held.
  Releasing it lets the next probe classify the radio as a MeshCore bridge.
  """
  def disconnect_unidentified do
    list_health()
    |> Enum.filter(&unidentified_companion?/1)
    |> Enum.each(fn health ->
      port = health[:port]

      try do
        GenServer.call(target(port), :disconnect, 2_000)
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end

  defp unidentified_companion?(health) when is_map(health) do
    status = health[:status]
    ref = health[:self_ref] || health[:node_id]

    status in [:online, :live, :running] and (is_nil(ref) or ref == "")
  end

  defp unidentified_companion?(_), do: false

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

  # BLE admin is get-then-set over GATT write-with-response. USB finishes in a
  # few seconds; BLE often needs the full handshake after the caller already
  # waited on the first write.
  defp admin_rpc_timeout(port, usb_ms) do
    if ble_admin_port?(port), do: max(usb_ms, 25_000), else: usb_ms
  end

  defp ble_admin_port?(port) when is_binary(port) do
    String.starts_with?(String.downcase(port), "ble:") or health_transport(port) == :ble
  end

  defp ble_admin_port?(port), do: health_transport(port) == :ble

  defp health_transport(port) do
    case health(port) do
      %{transport: transport} -> transport
      _ -> nil
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    Status.ensure_ets(@channels_table)
    Status.ensure_ets(@status_table)

    fixed_port? = Keyword.get(opts, :fixed_port, false)
    opt_port = Keyword.get(opts, :port)

    transport_kind =
      cond do
        Keyword.get(opts, :transport) in [:ble, "ble"] -> :ble
        is_binary(opt_port) and String.starts_with?(opt_port, "ble:") -> :ble
        true -> :usb
      end

    ble_address =
      Keyword.get(opts, :ble_address) ||
        if(transport_kind == :ble and is_binary(opt_port), do: ble_address(opt_port)) ||
        nil

    ble_pin = Keyword.get(opts, :ble_pin) || System.get_env("ISTHMUS_MESHTASTIC_BLE_PIN")

    port =
      opt_port ||
        cond do
          transport_kind == :ble and is_binary(ble_address) and ble_address != "" ->
            ble_key(ble_address)

          transport_kind == :usb ->
            Discover.resolve_port(:meshtastic)

          true ->
            nil
        end

    key = if is_binary(port) and port != "", do: port, else: :none

    :ets.insert(@channels_table, {{:all, key}, []})
    :ets.insert(@status_table, {{:lora, key}, RadioConfig.empty()})
    :ets.insert(@status_table, {{:device, key}, DeviceConfig.empty()})

    state = %{
      uart: nil,
      transport_kind: transport_kind,
      transport: nil,
      port: port,
      fixed_port: fixed_port?,
      ble_address: ble_address,
      ble_pin: ble_pin,
      ble_name: Keyword.get(opts, :ble_name),
      reconnect_gen: 0,
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
      received: 0,
      history_requested: false,
      heartbeat_nonce: 2,
      files: [],
      xmodem: nil,
      xmodem_timer: nil,
      store_pull_timer: nil,
      config_timer: nil
    }

    cond do
      transport_kind == :ble and is_binary(ble_address) and ble_address != "" ->
        state =
          Status.publish_status(%{
            state
            | status: :connecting,
              last_error: "Connecting over Bluetooth…"
          })

        {:ok, state, {:continue, :connect}}

      true ->
        {:ok, maybe_connect(state)}
    end
  end

  @impl true
  def handle_continue(:connect, state) do
    {:noreply, maybe_connect(state)}
  end

  @impl true
  def handle_call(:health, _from, state) do
    health = Status.with_estimated_clock(Status.health_map(state))
    Status.publish_status(state)
    {:reply, health, state}
  end

  def handle_call(:disconnect, _from, state) do
    Link.close(state)

    state =
      Status.publish_status(%{
        state
        | uart: nil,
          transport: nil,
          buffer: <<>>,
          status: :disconnected,
          my_info: nil,
          last_error: "released for rediscovery"
      })

    {:reply, :ok, state}
  end

  def handle_call(:list_channels, _from, state) do
    {:reply, Status.cached_channel_list(state), state}
  end

  def handle_call({:get_channel, idx}, _from, state) when is_integer(idx) do
    {:reply, Map.get(state.channels, idx), state}
  end

  def handle_call({:send_channel_text, idx, text}, _from, state) do
    if Link.online?(state) do
      reply_write(state, Protocol.send_channel_text_frame(idx, text))
    else
      {:reply, {:error, :not_connected}, state}
    end
  end

  def handle_call({:send_text, node_ref, text}, _from, state) do
    cond do
      not Link.online?(state) ->
        {:reply, {:error, :not_connected}, state}

      true ->
        case Protocol.parse_node_id(node_ref) do
          {:ok, num} ->
            reply_write(state, Protocol.send_dm_text_frame(num, text))

          :error ->
            {:reply, {:error, :invalid_node_id}, state}
        end
    end
  end

  def handle_call({:set_channel, idx, name, psk}, from, state) do
    psk_bin = Admin.normalize_psk(psk)
    channel = %{index: idx, name: name, psk: psk_bin, role: Protocol.role_secondary()}
    Admin.begin_channel_write(from, state, channel)
  end

  def handle_call({:clear_channel, idx}, from, state) when idx in 1..7 do
    Admin.begin_channel_write(from, state, Status.empty_channel(idx))
  end

  def handle_call({:set_lora_config, params}, from, state) do
    cond do
      not Link.online?(state) ->
        {:reply, {:error, :not_connected}, state}

      is_map(state.admin) ->
        {:reply, {:error, :busy}, state}

      true ->
        case {state.my_info, RadioConfig.cast(params, state.lora || RadioConfig.empty())} do
          {%{my_node_num: num}, {:ok, lora}} when is_integer(num) and num > 0 ->
            frame = Protocol.get_config_admin_frame(num, :lora)

            case Link.write(state, frame) do
              :ok ->
                timer = Process.send_after(self(), :admin_timeout, Admin.timeout_ms(state))

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
                {:reply, {:error, reason}, %{state | last_error: inspect(reason)}}
            end

          {_, {:error, reason}} ->
            {:reply, {:error, reason}, state}

          _ ->
            {:reply, {:error, :not_ready}, state}
        end
    end
  end

  def handle_call({:set_settings, params}, from, state) do
    cond do
      not Link.online?(state) ->
        {:reply, {:error, :not_connected}, state}

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

  def handle_call({:set_time, tz}, from, state) do
    Admin.begin_time_sync(from, state, tz)
  end

  @impl true
  def handle_cast(:sync_channels, state) do
    if Link.online?(state) do
      {:noreply, Admin.request_config(state)}
    else
      {:noreply, state}
    end
  end

  def handle_cast(:reconnect, state) do
    cond do
      stay_connected?(state) and state[:transport_kind] != :ble ->
        {:noreply, state}

      true ->
        {:noreply,
         reconnect_state(%{state | fail_count: 0, reconnect_gen: reconnect_gen(state) + 1})}
    end
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

  def handle_info({:ble_frame, payload}, state) when is_binary(payload) do
    {:noreply, Inbound.handle_payload(state, payload)}
  end

  def handle_info({:ble_disconnected, address}, state) do
    current = state[:ble_address]

    cond do
      stay_connected?(state) and is_binary(current) and not same_ble_address?(address, current) ->
        {:noreply, state}

      is_nil(state[:transport]) ->
        {:noreply, state}

      true ->
        Link.close(state)
        state = schedule_reconnect(state, 2_000)

        {:noreply,
         Status.publish_status(%{
           state
           | uart: nil,
             transport: nil,
             status: :disconnected,
             last_error: "ble disconnected"
         })}
    end
  end

  def handle_info(:heartbeat, state) do
    if Link.online?(state) do
      nonce = next_heartbeat_nonce(state[:heartbeat_nonce])

      case Link.write(state, Protocol.heartbeat_frame(nonce)) do
        :ok ->
          Process.send_after(self(), :heartbeat, @heartbeat_ms)
          {:noreply, %{state | heartbeat_nonce: nonce}}

        {:error, reason} ->
          if ble_link_lost?(reason) do
            {:noreply, schedule_reconnect(%{state | last_error: inspect(reason)}, 1_000)}
          else
            Process.send_after(self(), :heartbeat, @heartbeat_ms)
            {:noreply, %{state | heartbeat_nonce: nonce, last_error: inspect(reason)}}
          end
      end
    else
      {:noreply, state}
    end
  end

  def handle_info(:xmodem_timeout, state) do
    {:noreply, Inbound.retry_or_finish_xmodem(%{state | xmodem_timer: nil})}
  end

  def handle_info(:pull_message_store, state) do
    {:noreply, Inbound.request_message_store(%{state | store_pull_timer: nil})}
  end

  def handle_info({:reconnect, gen}, state) do
    cond do
      gen != reconnect_gen(state) ->
        {:noreply, state}

      stay_connected?(state) ->
        {:noreply, state}

      true ->
        Link.close(state)
        state = maybe_connect(%{state | uart: nil, transport: nil, status: :disconnected})
        {:noreply, state}
    end
  end

  def handle_info(:reconnect, state) do
    handle_info({:reconnect, reconnect_gen(state)}, state)
  end

  def handle_info(:ble_handshake, state) do
    if Link.online?(state) do
      {:noreply, Admin.request_config(state)}
    else
      {:noreply, state}
    end
  end

  def handle_info(:config_sync_timeout, state) do
    Logger.warning("Meshtastic config dump timed out — publishing what was collected")

    {:noreply,
     state
     |> Map.put(:config_timer, nil)
     |> Status.persist_channels()
     |> Status.broadcast_channels()
     |> Status.persist_lora()
     |> Status.broadcast_lora()
     |> Status.persist_device()
     |> Status.broadcast_device()
     |> Inbound.finish_config_dump(history: false)}
  end

  def handle_info(:admin_timeout, %{admin: admin} = state) when is_map(admin) do
    if admin[:from], do: GenServer.reply(admin.from, {:error, :timeout})

    state =
      if admin[:kind] == :read_lora do
        Admin.maybe_begin_time_sync(%{state | admin: nil})
      else
        %{state | admin: nil, last_error: "admin timeout"}
      end

    {:noreply, state}
  end

  def handle_info(:admin_timeout, state), do: {:noreply, state}

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Status.drop_ets(state)
    Link.close(state)
    :ok
  end

  defp maybe_connect(%{transport_kind: :usb, port: port} = state) when port in [nil, ""] do
    Status.publish_status(%{
      state
      | status: :disabled,
        last_error: "no companion detected (set ISTHMUS_MESHTASTIC_PORT to override)"
    })
  end

  defp maybe_connect(%{transport_kind: :ble, ble_address: addr} = state)
       when addr in [nil, ""] do
    Status.publish_status(%{
      state
      | status: :disabled,
        last_error: "ISTHMUS_MESHTASTIC_BLE_ADDRESS not set"
    })
  end

  defp maybe_connect(%{transport_kind: :ble} = state) do
    case BLETransport.connect(%{
           address: state.ble_address,
           pin: state[:ble_pin],
           owner: self()
         }) do
      {:ok, transport} ->
        Logger.info("Meshtastic companion online via Bluetooth #{state.ble_address}")

        _ =
          Isthmus.Networks.BLERemembered.remember(:meshtastic, state.ble_address,
            name: state[:ble_name]
          )

        Process.send_after(self(), :heartbeat, @heartbeat_ms)
        Process.send_after(self(), :ble_handshake, 400)

        Status.publish_status(%{
          state
          | transport: transport,
            uart: nil,
            status: :online,
            last_error: nil,
            fail_count: 0,
            buffer: <<>>,
            reconnect_gen: reconnect_gen(state) + 1
        })

      {:error, reason} ->
        fail_connect(state, reason)
    end
  end

  defp maybe_connect(state) do
    case Circuits.UART.start_link() do
      {:ok, uart} ->
        case Circuits.UART.open(uart, state.port, speed: @baud, active: true) do
          :ok ->
            Isthmus.Networks.Uart.prepare(uart, state.port)
            Logger.info("Meshtastic companion online via #{state.port}")
            Process.send_after(self(), :heartbeat, @heartbeat_ms)

            %{
              state
              | uart: uart,
                transport: nil,
                status: :online,
                last_error: nil,
                fail_count: 0,
                buffer: <<>>
            }
            |> Admin.request_config()
            |> Status.publish_status()

          {:error, reason} ->
            Isthmus.Networks.Uart.release(uart)
            fail_connect(state, reason)
        end

      {:error, reason} ->
        fail_connect(state, reason)
    end
  end

  defp fail_connect(state, reason) do
    Logger.warning("Meshtastic companion connect failed: #{inspect(reason)}")
    delay = reconnect_delay(reason, state)
    state = schedule_reconnect(state, delay)

    Status.publish_status(%{
      state
      | uart: nil,
        transport: nil,
        status: if(ble_transient_error?(reason), do: :connecting, else: :error),
        last_error: format_connect_error(reason),
        fail_count: (state[:fail_count] || 0) + 1
    })
  end

  # Opening CP210x/CH340 pulses DTR and reboots ESP32 Meshtastic firmware.
  # Rescan only needs a new UART when this companion is down or the port moved.
  @doc false
  def stay_connected?(state) when is_map(state) do
    online? = Link.online?(state)

    cond do
      not online? ->
        false

      state[:fixed_port] == true ->
        true

      state[:transport_kind] == :ble ->
        true

      true ->
        Discover.resolve_port(:meshtastic) == state[:port]
    end
  end

  defp reconnect_state(%{fixed_port: true} = state) do
    if is_reference(state[:config_timer]), do: Process.cancel_timer(state.config_timer)
    Link.close(state)

    %{
      state
      | uart: nil,
        transport: nil,
        buffer: <<>>,
        admin: nil,
        config_timer: nil,
        my_info: nil,
        channels: %{},
        lora: RadioConfig.empty(),
        device: DeviceConfig.empty(),
        device_time: nil,
        device_time_at: nil,
        time_synced_at: nil,
        device_tzdef: nil,
        history_requested: false,
        files: [],
        xmodem: nil,
        xmodem_timer: nil,
        store_pull_timer: nil
    }
    |> maybe_connect()
  end

  defp reconnect_state(state) do
    if is_reference(state[:config_timer]), do: Process.cancel_timer(state.config_timer)
    Link.close(state)

    port =
      if state[:transport_kind] == :ble do
        state.port
      else
        Discover.resolve_port(:meshtastic)
      end

    %{
      state
      | uart: nil,
        transport: nil,
        buffer: <<>>,
        port: port,
        admin: nil,
        config_timer: nil,
        my_info: nil,
        channels: %{},
        lora: RadioConfig.empty(),
        device: DeviceConfig.empty(),
        device_time: nil,
        device_time_at: nil,
        time_synced_at: nil,
        device_tzdef: nil,
        history_requested: false,
        files: [],
        xmodem: nil,
        xmodem_timer: nil,
        store_pull_timer: nil
    }
    |> maybe_connect()
  end

  defp schedule_reconnect(state, delay \\ @reconnect_ms) do
    Link.close(state)
    gen = reconnect_gen(state) + 1
    Process.send_after(self(), {:reconnect, gen}, delay)

    Status.publish_status(%{
      state
      | uart: nil,
        transport: nil,
        status: :error,
        reconnect_gen: gen
    })
  end

  defp reconnect_gen(state), do: state[:reconnect_gen] || 0

  defp reconnect_delay(reason, state) do
    text = reason |> to_string() |> String.downcase()

    cond do
      String.contains?(text, "inprogress") or String.contains?(text, "already in progress") ->
        12_000

      String.contains?(text, "timeout") or String.contains?(text, "not_found") ->
        8_000

      ble_transient_error?(reason) ->
        2_000

      true ->
        base =
          case reason do
            :eacces -> 30_000
            :bleak_missing -> 60_000
            "bleak_missing" -> 60_000
            :missing_ble_address -> 60_000
            _ -> @reconnect_ms
          end

        fails = state[:fail_count] || 0
        min(120_000, base * max(1, fails + 1))
    end
  end

  defp ble_transient_error?(reason) do
    text = reason |> to_string() |> String.downcase()

    String.contains?(text, "inprogress") or
      String.contains?(text, "already in progress") or
      String.contains?(text, "failed to discover services") or
      String.contains?(text, "device disconnected") or
      String.contains?(text, "timeout") or
      String.contains?(text, "powered_off") or
      String.contains?(text, "no powered bluetooth") or
      String.contains?(text, "not_found")
  end

  defp format_connect_error(reason) do
    text = reason |> to_string() |> String.trim()

    down = String.downcase(text)

    cond do
      String.contains?(down, "not_found") ->
        "Radio is not advertising yet — retrying Bluetooth…"

      String.contains?(down, "timeout") ->
        "Bluetooth connect timed out — retrying…"

      String.contains?(down, "inprogress") ->
        "Waiting for the Bluetooth adapter…"

      true ->
        text
    end
  end

  defp next_heartbeat_nonce(n) when is_integer(n) and n >= 2 do
    next = n + 1
    if next == 1, do: 2, else: next
  end

  defp next_heartbeat_nonce(_), do: 2

  defp reply_write(state, frame) do
    case Link.write(state, frame) do
      :ok ->
        {:reply, :ok, %{state | sent: state.sent + 1}}

      {:error, reason} ->
        state =
          if ble_link_lost?(reason) do
            schedule_reconnect(%{state | last_error: inspect(reason)}, 1_000)
          else
            %{state | last_error: inspect(reason)}
          end

        {:reply, {:error, reason}, state}
    end
  end
end
