defmodule Isthmus.Networks.MeshCore.BLETransport do
  @moduledoc """
  BLE companion transport stub.

  Real GATT bridging (e.g. via BlueHeron / a platform BLE stack) is not wired yet.
  Set `ISTHMUS_MESHCORE_TRANSPORT=ble` and `ISTHMUS_MESHCORE_BLE_ADDRESS=<mac>` to
  exercise the selection path; connect returns `{:error, :ble_not_implemented}` until
  a platform-specific backend is added.
  """
  @behaviour Isthmus.Networks.MeshCore.Transport

  @impl true
  def connect(opts) do
    address = opts[:address] || System.get_env("ISTHMUS_MESHCORE_BLE_ADDRESS")

    if is_binary(address) and address != "" do
      {:error, {:ble_not_implemented, address}}
    else
      {:error, :missing_ble_address}
    end
  end

  @impl true
  def write(_state, _data), do: {:error, :not_connected}

  @impl true
  def close(_state), do: :ok

  @impl true
  def info(_state), do: %{type: :ble, status: :stub}
end
