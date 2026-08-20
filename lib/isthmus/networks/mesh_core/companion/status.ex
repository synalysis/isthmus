defmodule Isthmus.Networks.MeshCore.Companion.Status do
  @moduledoc false

  @channels_table :isthmus_meshcore_channels
  @status_table :isthmus_meshcore_status
  @max_channel_slots 8

  @spec channels_table() :: atom()
  def channels_table, do: @channels_table

  @spec status_table() :: atom()
  def status_table, do: @status_table

  @spec max_channel_slots() :: pos_integer()
  def max_channel_slots, do: @max_channel_slots

  @spec ets_port_key(term()) :: String.t() | :none
  def ets_port_key(nil), do: Isthmus.Networks.MeshCore.Discover.resolve_port(:companion) || :none
  def ets_port_key(:primary), do: ets_port_key(nil)
  def ets_port_key(port) when is_binary(port) and port != "", do: port
  def ets_port_key(_), do: :none

  @spec ensure_ets(atom()) :: atom()
  def ensure_ets(name) do
    case :ets.whereis(name) do
      :undefined -> :ets.new(name, [:named_table, :public, :set, read_concurrency: true])
      _ -> name
    end
  end

  @spec drop_ets(map()) :: :ok
  def drop_ets(state) do
    drop_port(ets_port_key(state.port))
  end

  @spec drop_port(term()) :: :ok
  def drop_port(key) do
    :ets.delete(@status_table, {:health, key})
    :ets.delete(@channels_table, {:all, key})

    Enum.each(0..(@max_channel_slots - 1), fn idx ->
      :ets.delete(@channels_table, {idx, key})
    end)

    :ok
  rescue
    _ -> :ok
  end

  @doc "Remove leftover BLE health rows after Disconnect, even if the process is gone."
  @spec drop_matching_ble(String.t()) :: :ok
  def drop_matching_ble(address) when is_binary(address) do
    want = Isthmus.Networks.MeshCore.Companion.ble_address(address)

    @status_table
    |> :ets.match({{:health, :"$1"}, :"$2"})
    |> Enum.each(fn [key, health] ->
      have =
        health[:ble_address] ||
          if(is_binary(key), do: Isthmus.Networks.MeshCore.Companion.ble_address(key))

      if is_binary(key) and String.starts_with?(key, "ble:") and
           is_binary(have) and
           Isthmus.Networks.MeshCore.Companion.ble_address(have) == want do
        drop_port(key)
      end
    end)

    :ok
  rescue
    _ -> :ok
  end

  @spec cached_channel_list(map()) :: [map()]
  def cached_channel_list(state) do
    state.channels
    |> Map.values()
    |> Enum.sort_by(& &1.index)
  end

  @spec persist_channels(map()) :: map()
  def persist_channels(state) do
    channels = cached_channel_list(state)
    key = ets_port_key(state.port)
    :ets.insert(@channels_table, {{:all, key}, channels})

    Enum.each(channels, fn ch ->
      :ets.insert(@channels_table, {{ch.index, key}, ch})
    end)

    state
  end

  @spec health_map(map()) :: map()
  def health_map(state) do
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
      firmware_version: state[:firmware_version],
      firmware_model: state[:firmware_model],
      primary?: state[:fixed_port] != true
    }
  end

  @spec publish(map()) :: map()
  def publish(state) do
    :ets.insert(@status_table, {{:health, ets_port_key(state.port)}, health_map(state)})
    state
  end
end
