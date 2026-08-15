defmodule Isthmus.Networks.Meshtastic.Companion.Status do
  @moduledoc false

  require Logger

  alias Isthmus.Networks.MeshCore.Discover
  alias Isthmus.Networks.Meshtastic.DeviceConfig
  alias Isthmus.Networks.Meshtastic.Protocol
  alias Isthmus.Networks.Meshtastic.RadioConfig

  @channels_table :isthmus_meshtastic_channels
  @status_table :isthmus_meshtastic_status
  @max_channel_slots 8

  @spec channels_table() :: atom()
  def channels_table, do: @channels_table

  @spec status_table() :: atom()
  def status_table, do: @status_table

  @spec max_channel_slots() :: pos_integer()
  def max_channel_slots, do: @max_channel_slots

  def ets_port_key(nil), do: Discover.resolve_port(:meshtastic) || :none
  def ets_port_key(:primary), do: Discover.resolve_port(:meshtastic) || :none
  def ets_port_key(port) when is_binary(port) and port != "", do: port
  def ets_port_key(_), do: :none

  def ensure_ets(name) do
    case :ets.whereis(name) do
      :undefined -> :ets.new(name, [:named_table, :public, :set, read_concurrency: true])
      _ -> name
    end
  end

  def put_channel(state, %{index: idx} = channel) when is_integer(idx) do
    channel = channel_map(channel)
    key = state_ets_key(state)
    :ets.insert(@channels_table, {{idx, key}, channel})
    state = %{state | channels: Map.put(state.channels, idx, channel)}
    persist_channels(state)
  end

  def persist_channels(state) do
    list = cached_channel_list(state)
    :ets.insert(@channels_table, {{:all, state_ets_key(state)}, list})
    state
  end

  def persist_lora(state) do
    lora = state.lora || RadioConfig.empty()
    :ets.insert(@status_table, {{:lora, state_ets_key(state)}, lora})
    publish_status(state)
  end

  def persist_device(state) do
    device = state.device || DeviceConfig.empty()
    :ets.insert(@status_table, {{:device, state_ets_key(state)}, device})
    publish_status(%{state | device_tzdef: device[:tzdef] || state[:device_tzdef]})
  end

  def broadcast_lora(state) do
    Phoenix.PubSub.broadcast(
      Isthmus.PubSub,
      "meshtastic:lora",
      {:meshtastic_lora, state.lora || RadioConfig.empty(), state.port}
    )

    state
  end

  def broadcast_device(state) do
    Phoenix.PubSub.broadcast(
      Isthmus.PubSub,
      "meshtastic:device",
      {:meshtastic_device, state.device || DeviceConfig.empty(), state.port}
    )

    state
  end

  def cached_channel_list(state) do
    Enum.map(0..(@max_channel_slots - 1), fn idx ->
      Map.get(state.channels, idx) || empty_channel(idx)
    end)
  end

  def empty_channel(idx) do
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

  def channel_map(ch) do
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

  def broadcast_channels(state) do
    Phoenix.PubSub.broadcast(
      Isthmus.PubSub,
      "meshtastic:channels",
      {:meshtastic_channels, cached_channel_list(state), state.port}
    )

    state
  end

  def health_map(state) do
    lora = state.lora || RadioConfig.empty()
    port = state.port

    %{
      status: state.status,
      port: port,
      id: port || "none",
      primary?: state[:fixed_port] != true,
      transport: if(state[:transport_kind] == :ble, do: :ble, else: :usb),
      ble_address: state[:ble_address],
      name: state[:ble_name],
      detail:
        if(state[:transport_kind] == :ble,
          do: "Meshtastic Bluetooth companion",
          else: "Meshtastic serial companion"
        ),
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

  def publish_status(state) do
    :ets.insert(@status_table, {{:health, state_ets_key(state)}, health_map(state)})
    state
  end

  def state_ets_key(%{port: port}) when is_binary(port) and port != "", do: port
  def state_ets_key(_), do: :none

  def drop_ets(state) do
    drop_port(state_ets_key(state))
  end

  def drop_port(key) do
    :ets.delete(@status_table, {:health, key})
    :ets.delete(@status_table, {:lora, key})
    :ets.delete(@status_table, {:device, key})
    :ets.delete(@channels_table, {:all, key})
    :ok
  rescue
    _ -> :ok
  end

  def drop_matching_ble(address) when is_binary(address) do
    want = Isthmus.Networks.Meshtastic.Companion.normalize_ble_address(address)

    @status_table
    |> :ets.match({{:health, :"$1"}, :"$2"})
    |> Enum.each(fn [key, health] ->
      have =
        health[:ble_address] ||
          if(is_binary(key), do: Isthmus.Networks.Meshtastic.Companion.ble_address(key))

      if is_binary(key) and String.starts_with?(key, "ble:") and is_binary(have) and
           Isthmus.Networks.Meshtastic.Companion.same_ble_address?(have, want) do
        drop_port(key)
      end
    end)

    :ok
  rescue
    _ -> :ok
  end

  def with_estimated_clock(health) when is_map(health) do
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

  def with_estimated_clock(health), do: health

  def put_device_time(state, unix, opts \\ [])

  def put_device_time(state, unix, opts) when is_integer(unix) and unix > 1_000_000_000 do
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

  def put_device_time(state, _, _), do: state

  def valid_unix?(n) when is_integer(n) and n > 1_000_000_000, do: true
  def valid_unix?(_), do: false
end
