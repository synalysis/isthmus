defmodule Isthmus.Networks.MeshCore.BridgeCLITest do
  use ExUnit.Case, async: true

  alias Isthmus.Networks.MeshCore.BridgeCLI

  test "parse_radio_reply extracts freq/bw/sf/cr" do
    reply = "get radio\r\n  -> > 910.5250244,62.5,7,5\r\n"

    assert %{freq_mhz: freq, bw_khz: bw, sf: 7, cr: 5} = BridgeCLI.parse_radio_reply(reply)
    assert_in_delta freq, 910.5250244, 0.0001
    assert_in_delta bw, 62.5, 0.001
  end

  test "parse_tx_reply extracts dBm" do
    assert BridgeCLI.parse_tx_reply("get tx\r\n  -> > 10\r\n") == 10
  end

  defmodule FakeTransport do
    @moduledoc false
    @behaviour Isthmus.Networks.MeshCore.Transport

    @impl true
    def connect(%{port: port} = opts) do
      {:ok, %{port: port, test_pid: Map.fetch!(opts, :test_pid), replies: :queue.new()}}
    end

    @impl true
    def write(%{test_pid: pid} = t, data) do
      send(pid, {:cli_write, data})

      reply =
        cond do
          String.trim(data) == "" ->
            nil

          String.starts_with?(data, "get radio") ->
            "> 910.525,62.5,7,5\n"

          String.starts_with?(data, "get tx") ->
            "> 10\n"

          String.starts_with?(data, "set radio") ->
            "> OK\n"

          String.starts_with?(data, "set tx") ->
            "> OK\n"

          String.starts_with?(data, "reboot") ->
            "> OK\n"

          true ->
            "> ??:\n"
        end

      if is_binary(reply) do
        send(self(), {:circuits_uart, t.port, reply})
      end

      :ok
    end

    @impl true
    def close(_), do: :ok

    @impl true
    def info(%{port: port}), do: %{type: :fake, port: port}
  end

  test "set_radio and set_tx send CR-terminated CLI commands" do
    name = :"bridge_cli_#{System.unique_integer([:positive])}"
    test_pid = self()

    start_supervised!(
      {BridgeCLI,
       name: name,
       port: "/dev/fake_cli",
       transport_mod: FakeTransport,
       transport_opts: %{test_pid: test_pid}}
    )

    # Drain the boot get radio / get tx writes
    _ = :sys.get_state(name)
    flush_writes()

    assert :ok =
             BridgeCLI.set_radio(name, %{
               freq_mhz: 906.875,
               bw_khz: 62.5,
               sf: 8,
               cr: 5,
               tx_power: 10
             })

    assert_receive {:cli_write, "set radio 906.875,62.5,8,5\r"}, 1_000

    assert :ok = BridgeCLI.set_tx(name, 12)
    assert_receive {:cli_write, "set tx 12\r"}, 1_000
  end

  defp flush_writes do
    receive do
      {:cli_write, _} -> flush_writes()
    after
      100 -> :ok
    end
  end
end
