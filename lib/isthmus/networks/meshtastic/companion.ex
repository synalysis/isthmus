defmodule Isthmus.Networks.Meshtastic.Companion do
  @moduledoc """
  Meshtastic companion client over the serial protobuf API.

  Meshtastic companion client over the serial protobuf API.

  Port comes from auto-detect (`Discover`) or `ISTHMUS_MESHTASTIC_PORT`.
  Baud 115200. MeshCore companions are classified first (framed `<`/`>`), so a
  Meshtastic radio is only claimed when it answers `want_config` with `0x94 0xC3`
  FromRadio frames.

  Channel slots 0–7 on the radio can be linked to Isthmus bridge groups.
  Inbound TEXT_MESSAGE_APP broadcasts publish on `"meshtastic:inbound"`.
  """
  use GenServer

  require Logger

  alias Isthmus.Announce.Inbound
  alias Isthmus.Networks.MeshCore.Discover
  alias Isthmus.Networks.Meshtastic.Protocol
  alias Isthmus.Networks.Meshtastic.RadioConfig

  @channels_table :isthmus_meshtastic_channels
  @status_table :isthmus_meshtastic_status
  @max_channel_slots 8
  @heartbeat_ms 30_000
  @reconnect_ms 5_000
  @admin_timeout_ms 4_000
  @baud 115_200

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def health do
    case :ets.lookup(@status_table, :health) do
      [{:health, health}] -> health
      _ -> safe_call(:health, %{status: :unknown, last_error: "companion not ready"}, 500)
    end
  end

  @doc "Non-blocking read of cached channel slots (ETS)."
  def list_channels do
    case :ets.lookup(@channels_table, :all) do
      [{:all, channels}] when is_list(channels) and channels != [] ->
        channels

      _ ->
        Enum.map(0..(@max_channel_slots - 1), &empty_channel/1)
    end
  end

  def get_channel(idx) when is_integer(idx) do
    case :ets.lookup(@channels_table, idx) do
      [{^idx, channel}] -> channel
      _ -> nil
    end
  end

  @doc "Cached LoRa config from the last want_config dump."
  def lora_config do
    case :ets.lookup(@status_table, :lora) do
      [{:lora, config}] when is_map(config) -> config
      _ -> RadioConfig.empty()
    end
  end

  def sync_channels, do: GenServer.cast(__MODULE__, :sync_channels)
  def sync_channels_async, do: GenServer.cast(__MODULE__, :sync_channels)

  def set_channel(idx, name, psk \\ nil) when is_integer(idx) and is_binary(name) do
    safe_call({:set_channel, idx, name, psk}, {:error, :timeout}, 8_000)
  end

  def set_lora_config(params) when is_map(params) do
    safe_call({:set_lora_config, params}, {:error, :timeout}, 8_000)
  end

  def send_channel_text(idx, text) when is_integer(idx) and is_binary(text) do
    safe_call({:send_channel_text, idx, text}, {:error, :timeout}, 3_000)
  end

  def send_text(node_ref, text) when is_binary(node_ref) and is_binary(text) do
    safe_call({:send_text, node_ref, text}, {:error, :timeout}, 3_000)
  end

  def reconnect, do: GenServer.cast(__MODULE__, :reconnect)

  @doc "Inject a decoded inbound event (tests / future radio client)."
  def inject_inbound(kind, attrs) when kind in [:channel, :dm, :nodeinfo] and is_map(attrs) do
    GenServer.cast(__MODULE__, {:inject, kind, attrs})
  end

  defp safe_call(request, fallback, timeout) do
    GenServer.call(__MODULE__, request, timeout)
  catch
    :exit, _ -> fallback
  end

  @impl true
  def init(opts) do
    ensure_ets(@channels_table)
    ensure_ets(@status_table)
    :ets.insert(@channels_table, {:all, []})
    :ets.insert(@status_table, {:lora, RadioConfig.empty()})

    port =
      Keyword.get(opts, :port) || Discover.resolve_port(:meshtastic)

    state = %{
      uart: nil,
      port: port,
      buffer: <<>>,
      status: :disconnected,
      last_error: nil,
      fail_count: 0,
      channels: %{},
      lora: RadioConfig.empty(),
      my_info: nil,
      config_nonce: nil,
      admin: nil,
      sent: 0,
      received: 0
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

  def handle_call({:set_channel, idx, name, psk}, from, %{status: :online, uart: uart} = state)
      when not is_nil(uart) do
    cond do
      is_map(state.admin) ->
        {:reply, {:error, :busy}, state}

      true ->
        case state.my_info do
          %{my_node_num: num} when is_integer(num) and num > 0 ->
            psk_bin = normalize_psk(psk)
            channel = %{index: idx, name: name, psk: psk_bin, role: Protocol.role_secondary()}
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
  end

  def handle_call({:set_channel, _, _, _}, _from, state) do
    {:reply, {:error, :not_connected}, state}
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

  @impl true
  def handle_cast(:sync_channels, %{status: :online, uart: uart} = state) when not is_nil(uart) do
    {:noreply, request_config(state)}
  end

  def handle_cast(:sync_channels, state), do: {:noreply, state}

  def handle_cast(:reconnect, state) do
    {:noreply, reconnect(state)}
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
    {:noreply, reconnect(state)}
  end

  def handle_info(:admin_timeout, %{admin: %{from: from, timer: _}} = state) do
    GenServer.reply(from, {:error, :timeout})
    {:noreply, %{state | admin: nil, last_error: "admin timeout"}}
  end

  def handle_info(:admin_timeout, state), do: {:noreply, state}

  def handle_info(_msg, state), do: {:noreply, state}

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
        %{state | received: state.received + 1}

      {:channel, channel} ->
        put_channel(state, channel)

      {:config, {:lora, lora}} ->
        persist_lora(%{state | lora: lora})

      {:config, _} ->
        state

      {:config_complete, nonce} ->
        if state.config_nonce == nonce do
          persist_channels(state)
          broadcast_channels(state)
          persist_lora(state)
          broadcast_lora(state)
        end

        state

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
          meta: %{from: pkt.from, id: pkt.id}
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

  defp maybe_handle_admin(state, _), do: state

  defp put_channel(state, %{index: idx} = channel) when is_integer(idx) do
    channel = channel_map(channel)
    :ets.insert(@channels_table, {idx, channel})
    %{state | channels: Map.put(state.channels, idx, channel)}
  end

  defp persist_channels(state) do
    list = cached_channel_list(state)
    :ets.insert(@channels_table, {:all, list})
    state
  end

  defp persist_lora(state) do
    lora = state.lora || RadioConfig.empty()
    :ets.insert(@status_table, {:lora, lora})
    state
  end

  defp broadcast_lora(state) do
    Phoenix.PubSub.broadcast(
      Isthmus.PubSub,
      "meshtastic:lora",
      {:meshtastic_lora, state.lora || RadioConfig.empty()}
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
        case Circuits.UART.open(uart, state.port, speed: @baud, active: true) do
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

  defp reconnect(state) do
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
        lora: RadioConfig.empty()
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
      {:meshtastic_channels, cached_channel_list(state)}
    )
  end

  defp health_map(state) do
    lora = state.lora || RadioConfig.empty()

    %{
      status: state.status,
      port: state.port,
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
      tx_power: lora[:tx_power]
    }
  end

  defp publish_status(state) do
    :ets.insert(@status_table, {:health, health_map(state)})
    state
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
