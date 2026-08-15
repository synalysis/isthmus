defmodule Isthmus.Networks.MeshCore.BLETransport do
  @moduledoc """
  MeshCore companion transport over Bluetooth LE (Nordic UART Service).

  Frames are raw companion protocol bytes — one GATT notification is one frame.
  Uses `BLESidecar` (bleak) on Linux and macOS.
  """
  @behaviour Isthmus.Networks.MeshCore.Transport

  alias Isthmus.Networks.MeshCore.BLESidecar

  @impl true
  def connect(opts) when is_map(opts) do
    address = opts[:address] || opts["address"] || System.get_env("ISTHMUS_MESHCORE_BLE_ADDRESS")
    pin = opts[:pin] || opts["pin"] || System.get_env("ISTHMUS_MESHCORE_BLE_PIN")
    owner = opts[:owner] || self()
    sidecar = opts[:sidecar] || BLESidecar

    cond do
      not is_binary(address) or address == "" ->
        {:error, :missing_ble_address}

      true ->
        BLESidecar.watch(address, owner, sidecar)

        case BLESidecar.connect(address, pin, sidecar) do
          {:ok, info} ->
            {:ok, %{type: :ble, address: address, info: info, sidecar: sidecar}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @impl true
  def write(%{address: address} = state, data) when is_binary(data) do
    BLESidecar.write(address, data, state[:sidecar] || BLESidecar)
  end

  def write(_, _), do: {:error, :not_connected}

  @impl true
  def close(%{address: address} = state) do
    _ = BLESidecar.disconnect(address, state[:sidecar] || BLESidecar)
    :ok
  end

  def close(_), do: :ok

  @impl true
  def info(%{address: address} = state),
    do: %{type: :ble, status: :connected, address: address, info: state[:info]}

  def info(_), do: %{type: :ble, status: :disconnected}
end
