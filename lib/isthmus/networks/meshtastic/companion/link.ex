defmodule Isthmus.Networks.Meshtastic.Companion.Link do
  @moduledoc false

  alias Isthmus.Networks.Meshtastic.BLETransport
  alias Isthmus.Networks.Meshtastic.Protocol

  def online?(%{status: :online, transport_kind: :ble, transport: t}), do: not is_nil(t)
  def online?(%{status: :online, uart: uart}) when is_pid(uart), do: true
  def online?(_), do: false

  def write(%{transport_kind: :ble, transport: t}, frame) when not is_nil(t) do
    BLETransport.write(t, Protocol.ble_payload(frame))
  end

  def write(%{uart: uart}, frame) when is_pid(uart) do
    Circuits.UART.write(uart, frame)
  end

  def write(_, _), do: {:error, :not_connected}

  def close(%{transport_kind: :ble, transport: t}) when not is_nil(t) do
    BLETransport.close(t)
    :ok
  end

  def close(%{uart: uart}) when is_pid(uart) do
    Isthmus.Networks.Uart.release(uart)
    :ok
  end

  def close(_), do: :ok
end
