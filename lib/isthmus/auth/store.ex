defmodule Isthmus.Auth.Store do
  @moduledoc false
  use GenServer

  @table :isthmus_auth_challenges

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

    {:ok, %{table: table}}
  end
end
