defmodule Isthmus.Networks.Meshtastic.Supervisor do
  @moduledoc """
  Extra Meshtastic companion processes (USB ports besides the primary, plus BLE).

  The named `Isthmus.Networks.Meshtastic.Companion` still owns the primary USB
  port (`ISTHMUS_MESHTASTIC_PORT` or the first detected radio). Additional USB
  companions and BLE companions are started here via the Meshtastic registry.
  """
  use DynamicSupervisor

  alias Isthmus.Networks.BLERemembered
  alias Isthmus.Networks.MeshCore.BLESidecar
  alias Isthmus.Networks.MeshCore.Discover
  alias Isthmus.Networks.Meshtastic.Companion
  alias Isthmus.Networks.Meshtastic.Companion.Status

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
    primary = Discover.resolve_port(:meshtastic)

    wanted =
      Discover.resolve_ports(:meshtastic)
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
    restore_remembered_ble()
    :ok
  catch
    :exit, _ -> :ok
  end

  @doc "Start a BLE companion extra keyed by bleak address."
  def start_ble(address, pin \\ nil, opts \\ []) when is_binary(address) do
    case do_start_ble(address, pin, opts) do
      :ok ->
        BLERemembered.remember(:meshtastic, address, name: opts[:name] || opts["name"])
        :ok

      other ->
        other
    end
  end

  @doc "Stop a BLE companion extra and do not reconnect it after restart."
  def stop_ble(address) when is_binary(address) do
    addr = Companion.normalize_ble_address(address)
    BLERemembered.forget(:meshtastic, addr)
    _ = BLESidecar.disconnect(addr)

    running_keys()
    |> Enum.filter(&Companion.same_ble_address?(&1, addr))
    |> Enum.each(&stop_extra/1)

    Status.drop_matching_ble(addr)
    :ok
  end

  defp maybe_start_env_ble do
    case System.get_env("ISTHMUS_MESHTASTIC_BLE_ADDRESS") do
      addr when is_binary(addr) and addr != "" -> start_ble(addr)
      _ -> :ok
    end
  end

  defp restore_remembered_ble do
    for %{"address" => addr} = entry <- BLERemembered.list(:meshtastic) do
      opts = if is_binary(entry["name"]), do: [name: entry["name"]], else: []
      _ = do_start_ble(addr, nil, opts)
    end

    :ok
  end

  defp do_start_ble(address, pin, opts) do
    key = Companion.ble_key(address)
    pin = pin || System.get_env("ISTHMUS_MESHTASTIC_BLE_PIN")
    name = opts[:name] || opts["name"]

    spec = %{
      id: {:meshtastic_extra, key},
      start:
        {Companion, :start_link,
         [
           [
             name: Companion.via(key),
             port: key,
             transport: :ble,
             ble_address: Companion.ble_address(key),
             ble_pin: pin,
             ble_name: name,
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

  defp running_usb_ports do
    running_keys()
    |> Enum.reject(&String.starts_with?(&1, "ble:"))
    |> MapSet.new()
  end

  defp running_keys do
    Registry.select(Isthmus.Networks.Meshtastic.Registry, [
      {{:"$1", :_, :_}, [], [:"$1"]}
    ])
  rescue
    _ -> []
  end

  defp start_extra(port) when is_binary(port) do
    spec = %{
      id: {:meshtastic_extra, port},
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
    case Registry.lookup(Isthmus.Networks.Meshtastic.Registry, port) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      _ -> :ok
    end
  end
end
