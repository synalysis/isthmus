defmodule Mix.Tasks.Isthmus.Meshcore.Probe do
  @shortdoc "Probe MeshCore companion protocol over USB"

  @moduledoc """
  Exclusive serial probe for MeshCore companion communication.

  **Stop the Phoenix app first** — it holds `ISTHMUS_MESHCORE_PORT`.

      # Full suite: device handshake + contacts + channels
      mix isthmus.meshcore.probe

      # Individual steps
      mix isthmus.meshcore.probe --device
      mix isthmus.meshcore.probe --contacts
      mix isthmus.meshcore.probe --channels
      mix isthmus.meshcore.probe --channels --idx 1

      # Optional: write a test channel to slot 7 (overwrites that slot!)
      mix isthmus.meshcore.probe --set-dry --idx 7 --name ProbeTest

      # Options
      mix isthmus.meshcore.probe --port /dev/ttyACM0 --timeout 3000

  Loads `.env` for `ISTHMUS_MESHCORE_PORT` when present.
  """

  use Mix.Task

  @switches [
    device: :boolean,
    contacts: :boolean,
    channels: :boolean,
    set_dry: :boolean,
    port: :string,
    idx: :integer,
    name: :string,
    timeout: :integer,
    help: :boolean
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: @switches)

    if opts[:help] do
      Mix.shell().info(@moduledoc)
    else
      load_dotenv()
      Application.ensure_all_started(:circuits_uart)

      steps = selected_steps(opts)

      result =
        Isthmus.Networks.MeshCore.Probe.run(
          port: opts[:port],
          steps: steps,
          channel_idx: opts[:idx],
          name: opts[:name],
          timeout_ms: opts[:timeout]
        )

      result
      |> Isthmus.Networks.MeshCore.Probe.format_report()
      |> Enum.each(fn line -> Mix.shell().info(line) end)

      case result do
        {:ok, %{steps: step_results}} ->
          if Enum.all?(step_results, & &1.ok?), do: :ok, else: exit({:shutdown, 1})

        {:error, {:open_failed, :eagain}} ->
          Mix.shell().error("""

          Port busy (eagain/ebusy). Stop the Phoenix server first:

              # in the server terminal: Ctrl-C
              # then re-run this probe
          """)

          exit({:shutdown, 1})

        {:error, {:open_failed, reason}}
        when reason in [:eacces, :eperm] ->
          Mix.shell().error(
            "Permission denied — add user to dialout, or: sg dialout -c 'mix isthmus.meshcore.probe'"
          )

          exit({:shutdown, 1})

        {:error, _} ->
          exit({:shutdown, 1})
      end
    end
  end

  defp selected_steps(opts) do
    explicit =
      []
      |> maybe_add(opts[:device], :device)
      |> maybe_add(opts[:contacts], :contacts)
      |> maybe_add(opts[:channels], :channels)
      |> maybe_add(opts[:set_dry], :set_dry)

    if explicit == [], do: [:device, :contacts, :channels], else: explicit
  end

  defp maybe_add(list, true, step), do: list ++ [step]
  defp maybe_add(list, _, _), do: list

  defp load_dotenv do
    path = Path.expand(".env")

    if File.exists?(path) do
      path
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == "" or String.starts_with?(&1, "#")))
      |> Enum.each(fn line ->
        case String.split(line, "=", parts: 2) do
          [k, v] ->
            if System.get_env(k) in [nil, ""] do
              System.put_env(k, String.trim(v, "\"'"))
            end

          _ ->
            :ok
        end
      end)
    end
  end
end
