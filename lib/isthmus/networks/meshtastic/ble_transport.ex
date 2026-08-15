defmodule Isthmus.Networks.Meshtastic.BLETransport do
  @moduledoc """
  Meshtastic companion transport over Bluetooth LE (ToRadio / FromRadio / FromNum).

  Writes are raw ToRadio protobufs. Incoming FromRadio payloads are delivered
  to the companion as `{:ble_frame, payload}` via `MeshCore.BLESidecar`.
  """

  alias Isthmus.Networks.MeshCore.BLESidecar

  def connect(opts) when is_map(opts) do
    address =
      opts[:address] || opts["address"] || System.get_env("ISTHMUS_MESHTASTIC_BLE_ADDRESS")

    pin = opts[:pin] || opts["pin"] || System.get_env("ISTHMUS_MESHTASTIC_BLE_PIN")
    owner = opts[:owner] || self()
    sidecar = opts[:sidecar] || BLESidecar

    cond do
      not is_binary(address) or address == "" ->
        {:error, :missing_ble_address}

      true ->
        BLESidecar.watch(address, owner, sidecar)

        case BLESidecar.connect_profile(address, pin, "meshtastic", sidecar) do
          {:ok, info} ->
            {:ok, %{type: :ble, address: address, info: info, sidecar: sidecar}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  def write(%{address: address} = state, data) when is_binary(data) do
    BLESidecar.write(address, data, state[:sidecar] || BLESidecar)
  end

  def write(_, _), do: {:error, :not_connected}

  def close(%{address: address} = state) do
    _ = BLESidecar.disconnect(address, state[:sidecar] || BLESidecar)
    :ok
  end

  def close(_), do: :ok
end
