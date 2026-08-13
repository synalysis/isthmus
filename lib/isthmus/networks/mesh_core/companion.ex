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

  alias Isthmus.Announce.Inbound
  alias Isthmus.Announce.Sightings
  alias Isthmus.Networks.MeshCore.BLETransport
  alias Isthmus.Networks.MeshCore.Discover
  alias Isthmus.Networks.MeshCore.Protocol
  alias Isthmus.Networks.MeshCore.RadioParams
  alias Isthmus.Networks.MeshCore.USBTransport

  @channels_table :isthmus_meshcore_channels
  @status_table :isthmus_meshcore_status
  @registry Isthmus.Networks.MeshCore.Registry
  @max_channel_slots 8
  @max_channel_slots 8
  # Per-slot wait; overall deadline must cover worst case (all slots timing out).
  @channel_step_ms 1_000
  @channel_sync_slack_ms 2_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def via(port) when is_binary(port) do
    {:via, Registry, {@registry, port}}
  end

  def health(port \\ nil) do
    key = ets_port_key(port)

    case :ets.lookup(@status_table, {:health, key}) do
      [{_, health}] ->
        health

      _ ->
        safe_call(:health, %{status: :unknown, last_error: "companion not ready"}, 500, port)
    end
  end

  @doc "Health maps for every companion process (primary + extras)."
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
  def list_channels(port \\ nil) do
    case :ets.lookup(@channels_table, {:all, ets_port_key(port)}) do
      [{_, channels}] when is_list(channels) -> channels
      _ -> []
    end
  rescue
    _ -> []
  end

  def get_channel(idx, port \\ nil) when is_integer(idx) do
    case :ets.lookup(@channels_table, {idx, ets_port_key(port)}) do
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

  defp target(nil), do: __MODULE__
  defp target(:primary), do: __MODULE__

  defp target(port) when is_binary(port) do
    primary = Discover.resolve_port(:companion)
    if port == primary, do: __MODULE__, else: via(port)
  end

  defp ets_port_key(nil), do: Discover.resolve_port(:companion) || :none
  defp ets_port_key(:primary), do: Discover.resolve_port(:companion) || :none
  defp ets_port_key(port) when is_binary(port) and port != "", do: port
  defp ets_port_key(_), do: :none

  defp safe_call(request, fallback, timeout, port \\ nil) do
    GenServer.call(target(port), request, timeout)
  catch
    :exit, _ -> fallback
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    ensure_ets(@channels_table)
    ensure_ets(@status_table)

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
      channel_sync_timer: nil
    }

    state = maybe_connect(state)
    publish_status(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:health, _from, state) do
    health = health_map(state)
    publish_status(state)
    {:reply, health, state}
  end

  def handle_call(:list_channels, _from, state) do
    {:reply, cached_channel_list(state), state}
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
      |> maybe_abort_channel_sync({:error, :superseded})
      |> start_channel_sync(from)

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
    secret_bin = channel_secret_bin(secret)
    frame = Protocol.set_channel_frame(idx, name, secret_bin)

    case mod.write(t, Protocol.encode_usb_frame(frame)) do
      :ok ->
        channel = %{
          index: idx,
          name: name,
          secret_hex: Base.encode16(secret_bin, case: :lower),
          empty?: name == "" and zero_secret?(secret_bin)
        }

        state = put_in(state, [:channels, idx], channel) |> persist_channels()
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
  def handle_cast(:reconnect, %{fixed_port: true} = state) do
    if state.transport, do: state.transport_mod.close(state.transport)

    state = %{
      state
      | transport: nil,
        buffer: <<>>,
        status: :disconnected,
        self_info: nil
    }

    {:noreply, maybe_connect(state)}
  end

  def handle_cast(:reconnect, state) do
    if state.transport, do: state.transport_mod.close(state.transport)

    port =
      if state.transport_kind == :usb do
        Discover.resolve_port(:companion)
      else
        state.port
      end

    state = %{
      state
      | transport: nil,
        buffer: <<>>,
        status: :disconnected,
        port: port,
        self_info: nil
    }

    {:noreply, maybe_connect(state)}
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
      |> maybe_abort_channel_sync({:error, :superseded})
      |> start_channel_sync(nil)

    {:noreply, state}
  end

  def handle_cast(:sync_channels, state), do: {:noreply, state}

  @impl true
  def handle_info({:circuits_uart, _port, data}, state) when is_binary(data) do
    buffer = state.buffer <> data
    {frames, rest} = Protocol.decode_usb_stream(buffer)
    state = Enum.reduce(frames, %{state | buffer: rest}, &apply_frame/2)
    {:noreply, state}
  end

  def handle_info(:reconnect, state) do
    if state.transport, do: state.transport_mod.close(state.transport)
    state = maybe_connect(%{state | transport: nil, status: :disconnected})
    publish_status(state)
    {:noreply, state}
  end

  def handle_info(:poll_messages, %{status: :online, transport: t, transport_mod: mod} = state)
      when not is_nil(t) do
    _ = mod.write(t, Protocol.encode_usb_frame(Protocol.sync_next_message_frame()))
    schedule_poll()
    {:noreply, state}
  end

  def handle_info(:poll_messages, state) do
    schedule_poll()
    {:noreply, state}
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
    missing = missing_channel_indices(state)

    if missing != [] do
      Logger.debug(
        "MeshCore channel sync deadline — filling empty slots #{inspect(missing)} " <>
          "(have #{map_size(state.channels)}/#{state.max_channels})"
      )
    end

    state = fill_missing_channels(state, missing)
    {:noreply, finish_channel_sync(state, :ok)}
  end

  def handle_info({:channel_sync_step_timeout, idx}, %{channel_sync_awaiting: idx} = state)
      when not is_nil(idx) do
    Logger.debug("MeshCore channel #{idx} no response — treating as empty")
    state = put_in(state, [:channels, idx], empty_channel(idx))
    {:noreply, advance_channel_sync(state)}
  end

  def handle_info({:channel_sync_step_timeout, _idx}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{channel_sync_monitor: ref} = state) do
    {:noreply, clear_channel_sync(state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.transport, do: state.transport_mod.close(state.transport)
    if state[:fixed_port], do: drop_ets(state)
    :ok
  end

  defp drop_ets(state) do
    key = ets_port_key(state.port)
    :ets.delete(@status_table, {:health, key})
    :ets.delete(@channels_table, {:all, key})

    Enum.each(0..(@max_channel_slots - 1), fn idx ->
      :ets.delete(@channels_table, {idx, key})
    end)
  rescue
    _ -> :ok
  end

  defp apply_frame(frame, state) do
    case Protocol.parse_frame(frame) do
      {:raw_data, payload} ->
        # ISTH → Engine; otherwise MeshCore island bytes for meshcore-payload tunnels.
        Isthmus.Tunnel.Engine.ingest_carrier_blob("meshcore", payload, %{source: "companion_raw"})
        state

      {:advert, pubkey_hex} ->
        record_advert(pubkey_hex, state.contacts)
        Process.send_after(self(), :sync_contacts_boot, 500)
        state

      {:path_updated, pubkey_hex} ->
        Logger.debug("MeshCore path updated for #{pubkey_hex}")
        Process.send_after(self(), :sync_contacts_boot, 200)
        state

      {:contacts_start, count} ->
        Logger.info("MeshCore contacts sync starting (#{count})")
        state

      {:contact, contact} ->
        _ = record_contact_sighting(contact)
        put_in(state, [:contacts, contact.public_key], contact)

      {:end_of_contacts, lastmod} ->
        Logger.info("MeshCore contacts sync done (#{map_size(state.contacts)} contacts)")
        %{state | contacts_lastmod: lastmod}

      {:msg_waiting, true} ->
        send(self(), :poll_messages)
        state

      {:contact_msg, msg} ->
        maybe_record_peer_snr(msg)

        Phoenix.PubSub.broadcast(
          Isthmus.PubSub,
          "meshcore:inbound",
          {:meshcore_dm,
           %{
             from_ref: msg.from_ref,
             body: sanitize_text(msg.body),
             meta: Map.take(msg, [:timestamp, :txt_type, :snr, :score])
           }}
        )

        state

      {:channel_info, channel} ->
        state = put_in(state, [:channels, channel.index], channel)
        maybe_complete_awaited_channel(state, channel.index)

      {:error, :remote} ->
        # Firmware may ERROR on empty/unsupported slots during GET_CHANNEL.
        case state.channel_sync_awaiting do
          nil ->
            state

          idx ->
            state = put_in(state, [:channels, idx], empty_channel(idx))
            advance_channel_sync(state)
        end

      {:channel_msg, msg} ->
        Phoenix.PubSub.broadcast(
          Isthmus.PubSub,
          "meshcore:inbound",
          {:meshcore_channel,
           %{
             channel_idx: msg.channel_idx,
             body: sanitize_text(msg.body),
             meta:
               Map.merge(Map.take(msg, [:timestamp, :txt_type, :snr]), %{
                 radio_id: get_in(state, [:self_info, :public_key])
               })
           }}
        )

        state

      {:device_info, rest} ->
        %{state | max_channels: parse_max_channels(rest, state.max_channels)}

      {:self_info, %{public_key: pubkey} = info} when is_binary(pubkey) ->
        # Arrives once per connect, in reply to CMD_APP_START; republish so the
        # cached health map carries our own node key.
        publish_status(%{state | self_info: info})

      {:no_more_messages, _} ->
        state

      other ->
        Logger.debug("meshcore frame: #{inspect(other)}")
        state
    end
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

  defp record_advert(pubkey_hex, contacts) when is_map(contacts) do
    name =
      case Map.get(contacts, String.downcase(pubkey_hex || "")) do
        %{name: n} when is_binary(n) and n != "" -> n
        _ -> nil
      end

    Inbound.record_meshcore(pubkey_hex, name, "push_advert")
  end

  defp record_contact_sighting(%{public_key: ref, name: name})
       when is_binary(ref) and is_binary(name) and name != "" do
    Inbound.record_meshcore(ref, name, "contact")
  end

  defp record_contact_sighting(_), do: :ok

  defp maybe_record_peer_snr(%{from_ref: from_ref} = msg) when is_binary(from_ref) do
    snr = Map.get(msg, :snr)

    if snr != nil do
      _ =
        Sightings.record(%{
          network: "meshcore",
          direction: "in",
          identity_ref: from_ref,
          snr: snr / 4.0,
          meta: %{source: "contact_msg", score: Map.get(msg, :score)}
        })
    end
  end

  defp maybe_record_peer_snr(_), do: :ok

  defp sanitize_text(text) when is_binary(text) do
    text |> String.trim_trailing(<<0>>) |> String.trim()
  end

  defp reply_write(mod, transport, frame, state) do
    case mod.write(transport, Protocol.encode_usb_frame(frame)) do
      :ok -> {:reply, :ok, state}
      {:error, reason} -> {:reply, {:error, reason}, %{state | last_error: inspect(reason)}}
    end
  end

  defp maybe_connect(%{transport_kind: :usb, port: nil} = state) do
    publish_status(%{
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
    publish_status(%{
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
        schedule_poll()
        Process.send_after(self(), :sync_contacts_boot, 1_000)

        publish_status(%{
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

        publish_status(%{
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

  defp schedule_poll, do: Process.send_after(self(), :poll_messages, 2_000)

  # Keyword lists only support atom Access keys — never use opts["k"] on them.
  defp truthy_opt?(opts, key) when is_list(opts) do
    opts[key] in [true, "true", "1", 1]
  end

  defp truthy_opt?(opts, key) when is_map(opts) do
    Map.get(opts, key) in [true, "true", "1", 1] or
      Map.get(opts, Atom.to_string(key)) in [true, "true", "1", 1]
  end

  defp truthy_opt?(_, _), do: false

  # Sequential GET_CHANNEL — firmware often cannot answer a burst of 8 queries.
  defp start_channel_sync(state, from) do
    monitor =
      case from do
        {pid, _} when is_pid(pid) -> Process.monitor(pid)
        _ -> nil
      end

    deadline = state.max_channels * @channel_step_ms + @channel_sync_slack_ms
    timer = Process.send_after(self(), :channel_sync_timeout, deadline)
    queue = Enum.to_list(0..(state.max_channels - 1))

    %{
      state
      | channel_sync_from: from,
        channel_sync_monitor: monitor,
        channel_sync_queue: queue,
        channel_sync_awaiting: nil,
        channel_sync_timer: timer
    }
    |> query_next_channel()
  end

  defp query_next_channel(%{status: :online, transport: t, transport_mod: mod} = state)
       when not is_nil(t) do
    case state.channel_sync_queue do
      [idx | rest] ->
        _ = mod.write(t, Protocol.encode_usb_frame(Protocol.get_channel_frame(idx)))
        Process.send_after(self(), {:channel_sync_step_timeout, idx}, @channel_step_ms)
        %{state | channel_sync_queue: rest, channel_sync_awaiting: idx}

      [] ->
        finish_channel_sync(state, :ok)
    end
  end

  defp query_next_channel(state), do: finish_channel_sync(state, {:error, :not_connected})

  defp maybe_complete_awaited_channel(%{channel_sync_awaiting: idx} = state, idx)
       when not is_nil(idx) do
    advance_channel_sync(state)
  end

  defp maybe_complete_awaited_channel(state, _idx), do: state

  defp advance_channel_sync(state) do
    %{state | channel_sync_awaiting: nil}
    |> query_next_channel()
  end

  defp finish_channel_sync(state, reason) do
    state = persist_channels(state)
    channels = cached_channel_list(state)

    reply =
      case reason do
        :ok -> {:ok, channels}
        :timeout -> {:ok, channels}
        {:error, _} = err -> err
      end

    if state.channel_sync_from do
      GenServer.reply(state.channel_sync_from, reply)
    end

    if reason in [:ok, :timeout] do
      Logger.info("MeshCore channel sync done (#{length(channels)} slots)")

      Phoenix.PubSub.broadcast(
        Isthmus.PubSub,
        "meshcore:channels",
        {:meshcore_channels, channels, state.port}
      )
    end

    clear_channel_sync(state)
  end

  defp maybe_abort_channel_sync(%{channel_sync_from: from} = state, reply)
       when not is_nil(from) do
    GenServer.reply(from, reply)
    clear_channel_sync(state)
  end

  defp maybe_abort_channel_sync(state, _reply), do: clear_channel_sync(state)

  defp clear_channel_sync(state) do
    if state.channel_sync_monitor, do: Process.demonitor(state.channel_sync_monitor, [:flush])
    if is_reference(state.channel_sync_timer), do: Process.cancel_timer(state.channel_sync_timer)

    %{
      state
      | channel_sync_from: nil,
        channel_sync_monitor: nil,
        channel_sync_queue: [],
        channel_sync_awaiting: nil,
        channel_sync_timer: nil
    }
  end

  defp empty_channel(idx) do
    %{
      index: idx,
      name: "",
      secret_hex: String.duplicate("00", 16),
      empty?: true
    }
  end

  defp missing_channel_indices(state) do
    have = MapSet.new(Map.keys(state.channels))

    remaining =
      [state.channel_sync_awaiting | state.channel_sync_queue]
      |> Enum.reject(&is_nil/1)

    0..(state.max_channels - 1)
    |> Enum.to_list()
    |> Enum.reject(&MapSet.member?(have, &1))
    |> Enum.concat(remaining)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp fill_missing_channels(state, indices) do
    Enum.reduce(indices, state, fn idx, acc ->
      if Map.has_key?(acc.channels, idx) do
        acc
      else
        put_in(acc, [:channels, idx], empty_channel(idx))
      end
    end)
  end

  defp ensure_ets(name) do
    case :ets.whereis(name) do
      :undefined -> :ets.new(name, [:named_table, :public, :set, read_concurrency: true])
      _ -> name
    end
  end

  defp parse_max_channels(<<fw, _max_contacts, max_channels, _::binary>>, _default)
       when fw >= 3 and max_channels > 0 do
    min(max_channels, @max_channel_slots)
  end

  defp parse_max_channels(_, default), do: default

  defp cached_channel_list(state) do
    state.channels
    |> Map.values()
    |> Enum.sort_by(& &1.index)
  end

  defp persist_channels(state) do
    channels = cached_channel_list(state)
    key = ets_port_key(state.port)
    :ets.insert(@channels_table, {{:all, key}, channels})

    Enum.each(channels, fn ch ->
      :ets.insert(@channels_table, {{ch.index, key}, ch})
    end)

    state
  end

  defp health_map(state) do
    info = state.self_info || %{}

    %{
      status: state.status,
      transport: state.transport_kind,
      port: state.port,
      ble_address: state.ble_address,
      last_error: state.last_error,
      contacts: map_size(state.contacts),
      channels: map_size(state.channels),
      max_channels: state.max_channels,
      self_ref: info[:public_key],
      self_name: info[:name],
      freq_mhz: info[:freq_mhz],
      bw_khz: info[:bw_khz],
      sf: info[:sf],
      cr: info[:cr],
      tx_power: info[:tx_power],
      max_tx_power: info[:max_tx_power],
      primary?: state[:fixed_port] != true
    }
  end

  defp publish_status(state) do
    :ets.insert(@status_table, {{:health, ets_port_key(state.port)}, health_map(state)})
    state
  end

  defp channel_secret_bin(nil), do: :crypto.strong_rand_bytes(16)

  defp channel_secret_bin(secret) when is_binary(secret) do
    cond do
      byte_size(secret) == 16 ->
        secret

      String.match?(secret, ~r/^[0-9a-fA-F]{32}$/) ->
        {:ok, bin} = Base.decode16(secret, case: :mixed)
        bin

      true ->
        :crypto.strong_rand_bytes(16)
    end
  end

  defp zero_secret?(bin) when is_binary(bin),
    do: byte_size(bin) > 0 and :binary.bin_to_list(bin) |> Enum.all?(&(&1 == 0))
end
