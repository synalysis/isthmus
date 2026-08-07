defmodule Isthmus.Backup do
  @moduledoc """
  Offline-safe SQLite backup on `SIGHUP` (and callable via `backup_now/0`).

  Copies `DATABASE_PATH` (or the configured Repo path) to
  `ISTHMUS_BACKUP_DIR` / `<basename>.<timestamp>.bak`.
  """
  use GenServer

  require Logger

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def backup_now, do: GenServer.call(__MODULE__, :backup, 60_000)

  @impl true
  def init(_opts) do
    if function_exported?(:os, :set_signal, 2) do
      # Keep default SIGHUP behavior overridden so the VM does not exit.
      :os.set_signal(:sighup, :handle)
    end

    {:ok, %{}}
  end

  @impl true
  def handle_info(:sighup, state) do
    _ = do_backup()
    {:noreply, state}
  end

  # OTP delivers OS signals as messages on some setups; also accept raw atom.
  def handle_info({:signal, :sighup}, state), do: handle_info(:sighup, state)

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:backup, _from, state) do
    {:reply, do_backup(), state}
  end

  defp do_backup do
    src = database_path()
    dir = System.get_env("ISTHMUS_BACKUP_DIR") || Path.dirname(src)

    File.mkdir_p!(dir)
    stamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M%S")
    dest = Path.join(dir, "#{Path.basename(src)}.#{stamp}.bak")

    case File.cp(src, dest) do
      :ok ->
        Logger.info("SQLite backup written to #{dest}")
        :telemetry.execute([:isthmus, :backup], %{count: 1}, %{path: dest})
        {:ok, dest}

      {:error, reason} ->
        Logger.error("SQLite backup failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp database_path do
    System.get_env("DATABASE_PATH") ||
      case Application.get_env(:isthmus, Isthmus.Repo)[:database] do
        path when is_binary(path) -> path
        _ -> "isthmus.db"
      end
  end
end
