defmodule Isthmus.Networks.MeshCore.Companion do
  @moduledoc """
  MeshCore companion client.

  The named process owns the primary port (`ISTHMUS_MESHCORE_PORT` or the first
  detected companion). Extra USB companions are started via `MeshCore.Supervisor`
  and addressed by port.

  Transport selection via `ISTHMUS_MESHCORE_TRANSPORT` (`usb` default, `ble` stub):
  - USB: auto-detected by `Discover`, or pin with `ISTHMUS_MESHCORE_PORT`
  - BLE: `ISTHMUS_MESHCORE_BLE_ADDRESS=<mac>` (not implemented yet — see `BLETransport`)

  Maintains a contact table (pubkey → out_path) for path-aware raw sends.
  """
  use GenServer

  require Logger

  alias Isthmus.Networks.MeshCore.BLETransport
  alias Isthmus.Networks.MeshCore.Companion.Channels
  alias Isthmus.Networks.MeshCore.Companion.Frames
  alias Isthmus.Networks.MeshCore.Companion.Status
  alias Isthmus.Networks.MeshCore.Discover
  alias Isthmus.Networks.MeshCore.Protocol
  alias Isthmus.Networks.MeshCore.RadioParams
  alias Isthmus.Networks.MeshCore.USBTransport

  @channels_table :isthmus_meshcore_channels
  @status_table :isthmus_meshcore_status
  @registry Isthmus.Networks.MeshCore.Registry
  @max_channel_slots 8

  @type port_arg :: String.t() | nil | :primary
  @type health :: map()
  @type channel :: map()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
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
        health

      _ ->
        safe_call(:health, %{status: :unknown, last_error: "companion not ready"}, 500, port)
    end
  end

  @doc "Health maps for every companion process (primary + extras)."
  @spec list_health() :: [health()]
  def list_health do
    @status_table
    |> :ets.match({{:health, :_}, :"$1"})
    |> List.flatten()
    |> Enum.filter(&is_map/1)
    |> Enum.sort_by(&{if(&1[:primary?], do: 0, else: 1), &1[:port] || ""})
  rescue
    _ ->
      [health()]
  end

  @doc "Serial port owned by the companion with this public key, if any."
  def port_for_radio_id(nil), do: nil

  def port_for_radio_id(id) when is_binary(id) do
    want = id |> String.trim() |> String.downcase()

    list_health()
    |> Enum.find_value(fn health ->
      have =
        case health[:self_ref] do
          ref when is_binary(ref) -> String.downcase(ref)
          _ -> nil
        end

      if have == want and is_binary(health[:port]) and health[:port] != "", do: health[:port]
    end)
  end

  def list_contacts, do: safe_call(:list_contacts, [], 1_000)
  def get_contact(pubkey_hex), do: safe_call({:get_contact, pubkey_hex}, nil, 1_000)
  def sync_contacts, do: GenServer.cast(__MODULE__, :sync_contacts)

  @doc "Non-blocking read of cached channel slots (ETS)."
  @spec list_channels() :: [channel()]
  @spec list_channels(port_arg()) :: [channel()]
  def list_channels(port \\ nil) do
    case :ets.lookup(@channels_table, {:all, Status.ets_port_key(port)}) do
      [{_, channels}] when is_list(channels) -> channels
      _ -> []
    end
  rescue
    _ -> []
  end

  @spec get_channel(integer()) :: channel() | nil
  @spec get_channel(integer(), port_arg()) :: channel() | nil
  def get_channel(idx, port \\ nil) when is_integer(idx) do
    case :ets.lookup(@channels_table, {idx, Status.ets_port_key(port)}) do
      [{_, channel}] -> channel
      _ -> nil
    end
  rescue
    _ -> nil
  end

  def sync_channels(port \\ nil), do: GenServer.cast(target(port), :sync_channels)

  @doc """
  Request a channel sync. Returns immediately; result broadcast on
  PubSub topic `"meshcore:channels"` as `{:meshcore_channels, channels, port}`.
  """
  def sync_channels_async(port \\ nil), do: GenServer.cast(target(port), :sync_channels)

  def sync_channels_now(timeout \\ 8_000, port \\ nil) do
    safe_call(:sync_channels_now, {:error, :timeout}, timeout, port)
  end

  def set_channel(idx, name, secret \\ nil, port \\ nil)
      when is_integer(idx) and is_binary(name) do
    safe_call({:set_channel, idx, name, secret}, {:error, :timeout}, 3_000, port)
  end

  @doc "Empty a private slot on the companion (blank name, zero secret)."
  def clear_channel(idx, port \\ nil) when is_integer(idx) and idx in 1..7 do
    set_channel(idx, "", <<0::128>>, port)
  end

  def send_channel_text(idx, text, port \\ nil)
      when is_integer(idx) and is_binary(text) do
    safe_call({:send_channel_text, idx, text}, {:error, :timeout}, 3_000, port)
  end

  def send_raw(payload, opts \\ %{}) when is_binary(payload) do
    GenServer.call(__MODULE__, {:send_raw, payload, Map.new(opts)})
  end

  def send_text(pubkey_hex, text) when is_binary(pubkey_hex) and is_binary(text) do
    GenServer.call(__MODULE__, {:send_text, pubkey_hex, text})
  end

  def send_self_advert(opts \\ []) do
    GenServer.call(__MODULE__, {:send_self_advert, opts})
  end

  @doc "Apply radio frequency / bandwidth / SF / CR on the companion."
  def set_radio_params(params, port \\ nil) when is_map(params) do
    with {:ok, normalized} <- RadioParams.cast(params) do
      safe_call({:set_radio_params, normalized}, {:error, :timeout}, 5_000, port)
    end
  end

  @doc "Apply TX power (dBm) on the companion."
  def set_tx_power(tx, port \\ nil)

  def set_tx_power(tx, port) when is_integer(tx) and tx in 0..22 do
    safe_call({:set_tx_power, tx}, {:error, :timeout}, 5_000, port)
  end

  def set_tx_power(tx, _port) when is_integer(tx), do: {:error, "TX power must be 0–22 dBm"}

  def set_tx_power(tx, port) when is_binary(tx) do
    case Integer.parse(String.trim(tx)) do
      {n, _} -> set_tx_power(n, port)
      :error -> {:error, "invalid tx power"}
    end
  end

  @doc "Re-resolve the serial port (after Discover.refresh) and reconnect."
  def reconnect(port \\ nil), do: GenServer.cast(target(port), :reconnect)

  @doc """
  Close UART on companions that came online without a SELF_INFO handshake.

  Discovery used to treat ESP32 boot noise as MeshCore, then skip that port on
  Rescan because the UART was already held. Releasing it lets the next probe
  classify the radio as Meshtastic.
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
    ref = health[:self_ref]

    status in [:online, :live, :running] and (is_nil(ref) or ref == "")
  end

  defp unidentified_companion?(_), do: false

  defp target(nil), do: __MODULE__
  defp target(:primary), do: __MODULE__

  defp target(port) when is_binary(port) do
    primary = Discover.resolve_port(:companion)
    if port == primary, do: __MODULE__, else: via(port)
  end

  defp safe_call(request, fallback, timeout, port \\ nil) do
    GenServer.call(target(port), request, timeout)
  catch
    :exit, _ -> fallback
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    Status.ensure_ets(@channels_table)
    Status.ensure_ets(@status_table)

    fixed_port? = Keyword.get(opts, :fixed_port, false)

    transport_kind =
      cond do
        fixed_port? ->
          :usb

        true ->
          case System.get_env("ISTHMUS_MESHCORE_TRANSPORT", "usb") |> String.downcase() do
            "ble" -> :ble
            _ -> :usb
          end
      end

    port =
      Keyword.get(opts, :port) ||
        if(transport_kind == :usb, do: Discover.resolve_port(:companion), else: nil)

    key = if is_binary(port) and port != "", do: port, else: :none
    :ets.insert(@channels_table, {{:all, key}, []})

    state = %{
      transport_kind: transport_kind,
      transport_mod: if(transport_kind == :ble, do: BLETransport, else: USBTransport),
      transport: nil,
      port: port,
      fixed_port: fixed_port?,
      ble_address: System.get_env("ISTHMUS_MESHCORE_BLE_ADDRESS"),
      buffer: <<>>,
      status: :disconnected,
      last_error: nil,
      fail_count: 0,
      contacts: %{},
      contacts_lastmod: 0,
      channels: %{},
      self_info: nil,
      max_channels: @max_channel_slots,
      channel_sync_from: nil,
      channel_sync_monitor: nil,
      channel_sync_queue: [],
      channel_sync_awaiting: nil,
      channel_sync_timer: nil,
      pending_channel_msgs: [],
      msg_poll_timer: nil
    }

    state = maybe_connect(state)
    Status.publish(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:health, _from, state) do
    health = Status.health_map(state)
    Status.publish(state)
    {:reply, health, state}
  end

  def handle_call(:disconnect, _from, state) do
    if state.transport, do: state.transport_mod.close(state.transport)

    state =
      Status.publish(%{
        state
        | transport: nil,
          buffer: <<>>,
          status: :disconnected,
          self_info: nil,
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

  def handle_call(
        :sync_channels_now,
        from,
        %{status: :online, transport: t} = state
      )
      when not is_nil(t) do
    state =
      state
      |> Channels.maybe_abort({:error, :superseded})
      |> Channels.start(from)

    {:noreply, state}
  end

  def handle_call(:sync_channels_now, _from, state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call(
        {:set_channel, idx, name, secret},
        _from,
        %{status: :online, transport: t, transport_mod: mod} = state
      )
      when not is_nil(t) do
    secret_bin = Channels.channel_secret_bin(secret)
    frame = Protocol.set_channel_frame(idx, name, secret_bin)

    case mod.write(t, Protocol.encode_usb_frame(frame)) do
      :ok ->
        channel = %{
          index: idx,
          name: name,
          secret_hex: Base.encode16(secret_bin, case: :lower),
          empty?: name == "" and Channels.zero_secret?(secret_bin)
        }

        state = put_in(state, [:channels, idx], channel) |> Status.persist_channels()
        {:reply, {:ok, channel}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, %{state | last_error: inspect(reason)}}
    end
  end

  def handle_call({:set_channel, _, _, _}, _from, state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call(
        {:set_radio_params, params},
        _from,
        %{status: :online, transport: t, transport_mod: mod} = state
      )
      when not is_nil(t) do
    frame =
      Protocol.set_radio_params_frame(
        params.freq_mhz,
        params.bw_khz,
        params.sf,
        params.cr
      )

    case mod.write(t, Protocol.encode_usb_frame(frame)) do
      :ok ->
        _ = mod.write(t, Protocol.encode_usb_frame(Protocol.app_start_frame()))
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, %{state | last_error: inspect(reason)}}
    end
  end

  def handle_call({:set_radio_params, _}, _from, state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call(
        {:set_tx_power, tx},
        _from,
        %{status: :online, transport: t, transport_mod: mod} = state
      )
      when not is_nil(t) do
    frame = Protocol.set_tx_power_frame(tx)

    case mod.write(t, Protocol.encode_usb_frame(frame)) do
      :ok ->
        _ = mod.write(t, Protocol.encode_usb_frame(Protocol.app_start_frame()))
        {:reply, :ok, state}

      {:error, reason} ->
        {:reply, {:error, reason}, %{state | last_error: inspect(reason)}}
    end
  end

  def handle_call({:set_tx_power, _}, _from, state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call(
        {:send_channel_text, idx, text},
        _from,
        %{status: :online, transport: t, transport_mod: mod} = state
      )
      when not is_nil(t) do
    frame = Protocol.send_channel_txt_frame(idx, text)
    reply_write(mod, t, frame, state)
  end

  def handle_call({:send_channel_text, _, _}, _from, state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call(:list_contacts, _from, state) do
    {:reply, Map.values(state.contacts), state}
  end

  def handle_call({:get_contact, pubkey_hex}, _from, state) do
    key = String.downcase(pubkey_hex || "")
    {:reply, Map.get(state.contacts, key), state}
  end

  def handle_call(
        {:send_raw, payload, opts},
        _from,
        %{status: :online, transport: t, transport_mod: mod, contacts: contacts} = state
      )
      when not is_nil(t) do
    {path_len, path} = resolve_path(opts, contacts)
    frame = Protocol.send_raw_frame(path_len, path, payload)
    reply_write(mod, t, frame, state)
  end

  def handle_call({:send_raw, _payload, _opts}, _from, state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call(
        {:send_text, pubkey_hex, text},
        _from,
        %{status: :online, transport: t, transport_mod: mod} = state
      )
      when not is_nil(t) do
    case Base.decode16(pubkey_hex, case: :mixed) do
      {:ok, pk} when byte_size(pk) == 32 ->
        frame = Protocol.send_txt_msg_frame(pk, text)
        reply_write(mod, t, frame, state)

      _ ->
        {:reply, {:error, :invalid_pubkey}, state}
    end
  end

  def handle_call({:send_text, _, _}, _from, state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call(
        {:send_self_advert, opts},
        _from,
        %{status: :online, transport: t, transport_mod: mod} = state
      )
      when not is_nil(t) do
    flood? = truthy_opt?(opts, :flood)
    frame = Protocol.send_self_advert_frame(flood?)
    reply_write(mod, t, frame, state)
  end

  def handle_call({:send_self_advert, _}, _from, state) do
    {:reply, {:error, :not_connected}, state}
  end

  @impl true
  def handle_cast(:reconnect, state) do
    if stay_connected?(state) do
      {:noreply, state}
    else
      {:noreply, reconnect_state(state)}
    end
  end

  def handle_cast(:sync_contacts, %{status: :online, transport: t, transport_mod: mod} = state)
      when not is_nil(t) do
    frame =
      if state.contacts_lastmod > 0 do
        Protocol.get_contacts_since_frame(state.contacts_lastmod)
      else
        Protocol.get_contacts_frame()
      end

    _ = mod.write(t, Protocol.encode_usb_frame(frame))
    {:noreply, state}
  end

  def handle_cast(:sync_contacts, state), do: {:noreply, state}

  def handle_cast(:sync_channels, %{status: :online, transport: t} = state) when not is_nil(t) do
    state =
      state
      |> Channels.maybe_abort({:error, :superseded})
      |> Channels.start(nil)

    {:noreply, state}
  end

  def handle_cast(:sync_channels, state), do: {:noreply, state}

  @impl true
  def handle_info({:circuits_uart, _port, data}, state) when is_binary(data) do
    buffer = state.buffer <> data
    {frames, rest} = Protocol.decode_usb_stream(buffer)
    state = Enum.reduce(frames, %{state | buffer: rest}, &Frames.apply/2)
    {:noreply, state}
  end

  def handle_info(:reconnect, state) do
    if state.transport, do: state.transport_mod.close(state.transport)
    state = maybe_connect(%{state | transport: nil, status: :disconnected})
    Status.publish(state)
    {:noreply, state}
  end

  def handle_info(:poll_messages, %{status: :online, transport: t, transport_mod: mod} = state)
      when not is_nil(t) do
    _ = mod.write(t, Protocol.encode_usb_frame(Protocol.sync_next_message_frame()))
    {:noreply, %{state | msg_poll_timer: nil}}
  end

  def handle_info(:poll_messages, state), do: {:noreply, state}

  def handle_info(:drain_messages, state) do
    state = Frames.flush_pending(state)
    {:noreply, state} = handle_info(:poll_messages, state)
    {:noreply, state}
  end

  def handle_info(:schedule_msg_poll, state) do
    {:noreply, schedule_poll(state)}
  end

  def handle_info(:sync_contacts_boot, state) do
    {:noreply, state} = handle_cast(:sync_contacts, state)
    Process.send_after(self(), :sync_channels_boot, 300)
    {:noreply, state}
  end

  def handle_info(:sync_channels_boot, state) do
    {:noreply, state} = handle_cast(:sync_channels, state)
    {:noreply, state}
  end

  def handle_info(:channel_sync_timeout, state) do
    missing = Channels.missing_indices(state)

    if missing != [] do
      Logger.debug(
        "MeshCore channel sync deadline — filling empty slots #{inspect(missing)} " <>
          "(have #{map_size(state.channels)}/#{state.max_channels})"
      )
    end

    state = Channels.fill_missing(state, missing)
    {:noreply, Channels.finish(state, :ok)}
  end

  def handle_info({:channel_sync_step_timeout, idx}, %{channel_sync_awaiting: idx} = state)
      when not is_nil(idx) do
    Logger.debug("MeshCore channel #{idx} no response — treating as empty")
    state = put_in(state, [:channels, idx], Channels.empty_channel(idx))
    {:noreply, Channels.advance(state)}
  end

  def handle_info({:channel_sync_step_timeout, _idx}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{channel_sync_monitor: ref} = state) do
    {:noreply, Channels.clear(state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.transport, do: state.transport_mod.close(state.transport)
    if state[:fixed_port], do: Status.drop_ets(state)
    :ok
  end

  defp resolve_path(opts, contacts) do
    explicit_path = opts[:path] || opts["path"]
    peer_ref = opts[:peer_ref] || opts["peer_ref"]

    cond do
      is_binary(explicit_path) and explicit_path != "" ->
        path =
          case Base.decode16(explicit_path, case: :mixed) do
            {:ok, bin} -> bin
            _ -> explicit_path
          end

        {byte_size(path), path}

      is_binary(peer_ref) ->
        case Map.get(contacts, String.downcase(peer_ref)) do
          %{out_path_len: len, out_path: path}
          when is_integer(len) and len > 0 and is_binary(path) ->
            {len, path}

          _ ->
            {0, <<>>}
        end

      true ->
        {0, <<>>}
    end
  end

  defp reply_write(mod, transport, frame, state) do
    case mod.write(transport, Protocol.encode_usb_frame(frame)) do
      :ok -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, %{state | last_error: inspect(reason)}}
    end
  end

  defp stay_connected?(state) when is_map(state) do
    online? = state[:status] == :online and not is_nil(state[:transport])

    cond do
      not online? ->
        false

      state[:fixed_port] == true ->
        true

      state[:transport_kind] != :usb ->
        true

      true ->
        Discover.resolve_port(:companion) == state[:port]
    end
  end

  defp reconnect_state(%{fixed_port: true} = state) do
    if state.transport, do: state.transport_mod.close(state.transport)

    %{
      state
      | transport: nil,
        buffer: <<>>,
        status: :disconnected,
        self_info: nil
    }
    |> maybe_connect()
  end

  defp reconnect_state(state) do
    if state.transport, do: state.transport_mod.close(state.transport)

    port =
      if state.transport_kind == :usb do
        Discover.resolve_port(:companion)
      else
        state.port
      end

    %{
      state
      | transport: nil,
        buffer: <<>>,
        status: :disconnected,
        port: port,
        self_info: nil
    }
    |> maybe_connect()
  end

  defp maybe_connect(%{transport_kind: :usb, port: nil} = state) do
    Status.publish(%{
      state
      | status: :disabled,
        last_error: "no companion detected (set ISTHMUS_MESHCORE_PORT to override)"
    })
  end

  defp maybe_connect(%{transport_kind: :usb, port: ""} = state) do
    maybe_connect(%{state | port: nil})
  end

  defp maybe_connect(%{transport_kind: :ble, ble_address: addr} = state)
       when addr in [nil, ""] do
    Status.publish(%{
      state
      | status: :disabled,
        last_error: "ISTHMUS_MESHCORE_BLE_ADDRESS not set"
    })
  end

  defp maybe_connect(state) do
    opts =
      case state.transport_kind do
        :usb -> %{port: state.port}
        :ble -> %{address: state.ble_address}
      end

    case state.transport_mod.connect(opts) do
      {:ok, transport} ->
        _ =
          state.transport_mod.write(
            transport,
            Protocol.encode_usb_frame(Protocol.device_query_frame())
          )

        _ =
          state.transport_mod.write(
            transport,
            Protocol.encode_usb_frame(Protocol.app_start_frame())
          )

        Logger.info("MeshCore companion online via #{state.transport_kind}")
        Process.send_after(self(), :sync_contacts_boot, 1_000)

        Status.publish(%{
          state
          | transport: transport,
            status: :online,
            last_error: nil,
            fail_count: 0
        })

      {:error, reason} ->
        delay = reconnect_delay(reason, state)
        log_connect_failure(reason, delay)
        Process.send_after(self(), :reconnect, delay)

        Status.publish(%{
          state
          | status: :error,
            last_error: inspect(reason),
            fail_count: (state[:fail_count] || 0) + 1
        })
    end
  end

  defp reconnect_delay(reason, state) do
    base =
      case reason do
        :eacces -> 30_000
        {:ble_not_implemented, _} -> 60_000
        :missing_ble_address -> 60_000
        _ -> 5_000
      end

    fails = state[:fail_count] || 0
    min(120_000, base * max(1, fails + 1))
  end

  defp log_connect_failure(:eacces, delay) do
    Logger.warning(
      "MeshCore connect failed: permission denied (:eacces). " <>
        "Add your user to the `dialout` group (or chmod the device), then retry in #{div(delay, 1000)}s."
    )
  end

  defp log_connect_failure(reason, delay) do
    Logger.warning("MeshCore connect failed: #{inspect(reason)} (retry in #{div(delay, 1000)}s)")
  end

  defp schedule_poll(state) do
    if is_reference(state[:msg_poll_timer]), do: Process.cancel_timer(state.msg_poll_timer)
    %{state | msg_poll_timer: Process.send_after(self(), :poll_messages, 2_000)}
  end

  # Keyword lists only support atom Access keys — never use opts["k"] on them.
  defp truthy_opt?(opts, key) when is_list(opts) do
    opts[key] in [true, "true", "1", 1]
  end

  defp truthy_opt?(opts, key) when is_map(opts) do
    Map.get(opts, key) in [true, "true", "1", 1] or
      Map.get(opts, Atom.to_string(key)) in [true, "true", "1", 1]
  end

  defp truthy_opt?(_, _), do: false
end
