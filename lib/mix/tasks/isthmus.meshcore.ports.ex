defmodule Mix.Tasks.Isthmus.Meshcore.Ports do
  @shortdoc "List serial ports and suggest ISTHMUS_MESHCORE_PORT"

  @moduledoc """
  Enumerates host serial ports and suggests the best MeshCore companion candidate.

      mix isthmus.meshcore.ports

  Scores USB CDC / USB-UART adapters (CP210x, CH340, FTDI, Nordic, Espressif, …)
  and prints a recommended `ISTHMUS_MESHCORE_PORT=` line.
  """

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    # Circuits.UART NIF; no full app boot needed
    Application.ensure_all_started(:circuits_uart)

    Isthmus.Networks.MeshCore.Ports.format_report()
    |> Enum.each(fn line -> Mix.shell().info(line) end)
  end
end
