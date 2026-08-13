defmodule Isthmus.Networks.Uart do
  @moduledoc false

  @doc """
  Drop a Circuits.UART process without `close/1`.

  `Circuits.UART.close/1` talks to the C port with a 4s timeout. On nRF USB-CDC
  (Seeed Wio Tracker L1, RAK4631, …) that often `exit(:port_timed_out)` and
  crashes the UART GenServer. `:shutdown` lets the VM reap the port and is not
  logged as an error.
  """
  @spec release(pid() | nil) :: :ok
  def release(pid) when is_pid(pid) do
    Process.exit(pid, :shutdown)
    :ok
  end

  def release(_), do: :ok

  @doc "True for USB CDC ACM ports (nRF52 TinyUSB, SAMD, …)."
  @spec acm?(String.t()) :: boolean()
  def acm?(path) when is_binary(path) do
    String.contains?(path, "ttyACM") or String.contains?(path, "usbmodem")
  end

  def acm?(_), do: false

  @doc """
  Line-control after `Circuits.UART.open/3`.

  `rs232_dtr` is not a Circuits.UART open option — DTR is `set_dtr/2`. nRF CDC
  (Wio Tracker L1) only talks once DTR is asserted. Meshtastic-python also
  raises RTS; TinyUSB `tud_cdc_connected()` is DTR, but some nRF builds want
  both control-line bits. CP210x/CH340 ESP32 boards reset into the bootloader
  if DTR stays high, so USB-UART keeps DTR and RTS clear.
  """
  @spec prepare(pid(), String.t()) :: :ok
  def prepare(uart, path) when is_pid(uart) and is_binary(path) do
    acm? = acm?(path)
    _ = Circuits.UART.set_dtr(uart, acm?)
    _ = Circuits.UART.set_rts(uart, acm?)
    if acm?, do: Process.sleep(200)
    :ok
  catch
    :exit, _ -> :ok
  end

  def prepare(_, _), do: :ok
end
