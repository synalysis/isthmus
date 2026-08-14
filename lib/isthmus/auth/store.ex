defmodule Isthmus.Auth.Store do
  @moduledoc false
  use GenServer

  @table :isthmus_auth_challenges
  @sweep_ms 30_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def table, do: @table

  @impl true
  def init(_opts) do
    table =
      case :ets.whereis(@table) do
        :undefined ->
          :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])

        _tid ->
          @table
      end

    schedule_sweep()
    {:ok, %{table: table}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep_expired()
    schedule_sweep()
    {:noreply, state}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_ms)
  end

  defp sweep_expired do
    now = System.system_time(:second)

    @table
    |> :ets.tab2list()
    |> Enum.each(fn
      {key, %{expires_at: exp}} when is_integer(exp) and exp < now ->
        :ets.delete(@table, key)

      _ ->
        :ok
    end)
  end
end
