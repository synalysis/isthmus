defmodule Isthmus.Networks.UartTest do
  use ExUnit.Case, async: true

  alias Isthmus.Networks.Uart

  test "release is a no-op for nil" do
    assert :ok = Uart.release(nil)
  end

  test "acm? detects USB CDC ports" do
    assert Uart.acm?("/dev/ttyACM0")
    refute Uart.acm?("/dev/ttyUSB0")
  end

  test "prepare on an unopened UART does not crash" do
    {:ok, _} = Application.ensure_all_started(:circuits_uart)
    {:ok, uart} = Circuits.UART.start_link()

    try do
      assert :ok = Uart.prepare(uart, "/dev/ttyACM0")
      assert :ok = Uart.prepare(uart, "/dev/ttyUSB0")
    after
      Uart.release(uart)
    end
  end

  test "release shuts down a UART process without close" do
    {:ok, _} = Application.ensure_all_started(:circuits_uart)
    Process.flag(:trap_exit, true)
    {:ok, uart} = Circuits.UART.start_link()
    ref = Process.monitor(uart)

    assert :ok = Uart.release(uart)
    assert_receive {:DOWN, ^ref, :process, ^uart, :shutdown}, 500
  end
end
