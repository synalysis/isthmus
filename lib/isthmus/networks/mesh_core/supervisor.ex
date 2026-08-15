defmodule Isthmus.Networks.MeshCore.Supervisor do
  @moduledoc """
  Extra MeshCore companion processes (USB ports besides the primary, plus BLE).

  The named `Isthmus.Networks.MeshCore.Companion` still owns the primary USB
  port. Additional USB companions and BLE companions are started here via the
  MeshCore registry.
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

  @doc "Start/stop extra USB companions so they match Discover. BLE extras stay."
  def sync do
    primary = Discover.resolve_port(:companion)

    wanted =
      Discover.resolve_ports(:companion)
      |> Enum.reject(&(&1 == primary))
      |> MapSet.new()

    running = running_usb_ports()

    for port <- MapSet.difference(running, wanted) do
      stop_extra(port)
    end

    for port <- MapSet.difference(wanted, running) do
      start_extra(port)
    end

    maybe_start_env_ble()
    :ok
  catch
    :exit, _ -> :ok
  end

  @doc "Start a BLE companion extra keyed by bleak address."
  def start_ble(address, pin \\ nil) when is_binary(address) do
    key = Companion.ble_key(address)
    pin = pin || System.get_env("ISTHMUS_MESHCORE_BLE_PIN") || "123456"

    spec = %{
      id: {:meshcore_extra, key},
      start:
        {Companion, :start_link,
         [
           [
             name: Companion.via(key),
             port: key,
             transport: :ble,
             ble_address: Companion.ble_address(key),
             ble_pin: pin,
             fixed_port: true
           ]
         ]},
      restart: :transient
    }

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> Companion.reconnect(key)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Stop a BLE companion extra."
  def stop_ble(address) when is_binary(address) do
    stop_extra(Companion.ble_key(address))
  end

  defp maybe_start_env_ble do
    case System.get_env("ISTHMUS_MESHCORE_BLE_ADDRESS") do
      addr when is_binary(addr) and addr != "" -> start_ble(addr)
      _ -> :ok
    end
  end

  defp running_usb_ports do
    running_keys()
    |> Enum.reject(&String.starts_with?(&1, "ble:"))
    |> MapSet.new()
  end

  defp running_keys do
    Registry.select(Isthmus.Networks.MeshCore.Registry, [
      {{:"$1", :_, :_}, [], [:"$1"]}
    ])
  rescue
    _ -> []
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
