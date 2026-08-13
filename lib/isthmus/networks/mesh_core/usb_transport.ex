defmodule Isthmus.Networks.MeshCore.USBTransport do
  @moduledoc "USB serial transport via Circuits.UART."
  @behaviour Isthmus.Networks.MeshCore.Transport

  @impl true
  def connect(%{port: port} = _opts) when is_binary(port) do
    case Circuits.UART.start_link() do
      {:ok, uart} ->
        case Circuits.UART.open(uart, port, speed: 115_200, active: true) do
          :ok ->
            Isthmus.Networks.Uart.prepare(uart, port)
            {:ok, %{type: :usb, uart: uart, port: port}}

          {:error, reason} ->
            Isthmus.Networks.Uart.release(uart)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def connect(_), do: {:error, :missing_port}

  @impl true
  def write(%{uart: uart}, data), do: Circuits.UART.write(uart, data)

  @impl true
  def close(%{uart: uart}) do
    Isthmus.Networks.Uart.release(uart)
    :ok
  end

  @impl true
  def info(%{port: port}), do: %{type: :usb, port: port}
end
