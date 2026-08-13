defmodule Isthmus.Networks.MeshCore.Supervisor do
  @moduledoc """
  Extra MeshCore companion processes (one per USB port besides the primary).

  The named `Isthmus.Networks.MeshCore.Companion` still owns the primary port
  (`ISTHMUS_MESHCORE_PORT` or the first detected companion). Additional
  detected companions are started here via the MeshCore registry.
  """
  use DynamicSupervisor

  alias Isthmus.Networks.MeshCore.Companion
  alias Isthmus.Networks.MeshCore.Discover

  def start_link(opts \\ []) do
    case DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__) do
      {:ok, _pid} = ok ->
        _ = sync()
        ok

      other ->
        other
    end
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc "Start/stop extra companions so they match Discover's companion ports."
  def sync do
    primary = Discover.resolve_port(:companion)

    wanted =
      Discover.resolve_ports(:companion)
      |> Enum.reject(&(&1 == primary))
      |> MapSet.new()

    running = running_ports()

    for port <- MapSet.difference(running, wanted) do
      stop_extra(port)
    end

    for port <- MapSet.difference(wanted, running) do
      start_extra(port)
    end

    :ok
  catch
    :exit, _ -> :ok
  end

  defp running_ports do
    Registry.select(Isthmus.Networks.MeshCore.Registry, [
      {{:"$1", :_, :_}, [], [:"$1"]}
    ])
    |> MapSet.new()
  rescue
    _ -> MapSet.new()
  end

  defp start_extra(port) when is_binary(port) do
    spec = %{
      id: {:meshcore_extra, port},
      start:
        {Companion, :start_link, [[name: Companion.via(port), port: port, fixed_port: true]]},
      restart: :transient
    }

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, _} -> :ok
    end
  end

  defp stop_extra(port) when is_binary(port) do
    case Registry.lookup(Isthmus.Networks.MeshCore.Registry, port) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      _ -> :ok
    end
  end
end
