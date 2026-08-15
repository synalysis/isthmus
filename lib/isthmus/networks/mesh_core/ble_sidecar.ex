defmodule Isthmus.Networks.MeshCore.BLESidecar do
  @moduledoc """
  Python bleak sidecar for MeshCore Companion Bluetooth (Nordic UART Service).

  Request/response calls use `{:packet, 4}` JSON like `Reticulum.Sidecar`.
  TX notifications are delivered to the process that `watch/2`ed the address
  as `{:ble_frame, frame}`.
  """
  use GenServer

  require Logger

  @connect_timeout 45_000
  @scan_timeout 8_000
  @rpc_timeout 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def health(name \\ __MODULE__) do
    safe_call(name, :health, 2_000)
  catch
    :exit, _ -> %{status: :not_started, live: false}
  end

  @spec scan(pos_integer()) :: {:ok, [map()]} | {:error, term()}
  @spec scan(pos_integer(), atom() | pid()) :: {:ok, [map()]} | {:error, term()}
  def scan(timeout_ms \\ 5_000, name \\ __MODULE__) do
    safe_call(name, {:rpc, "scan", %{"timeout_ms" => timeout_ms}}, @scan_timeout + 2_000)
    |> case do
      {:ok, %{"devices" => devices}} when is_list(devices) ->
        {:ok, Enum.map(devices, &normalize_device/1)}

      {:error, reason} ->
        {:error, reason}

      {:error, reason, _} ->
        {:error, reason}

      other ->
        {:error, other}
    end
  end

  @spec connect(String.t(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  @spec connect(String.t(), String.t() | nil, atom() | pid()) :: {:ok, map()} | {:error, term()}
  def connect(address, pin \\ nil, name \\ __MODULE__) when is_binary(address) do
    payload = %{"address" => address}
    payload = if is_binary(pin) and pin != "", do: Map.put(payload, "pin", pin), else: payload

    case safe_call(name, {:rpc, "connect", payload}, @connect_timeout) do
      {:ok, msg} -> {:ok, msg}
      {:error, reason} -> {:error, reason}
      {:error, reason, _} -> {:error, reason}
      other -> {:error, other}
    end
  end

  @spec disconnect(String.t()) :: :ok | {:error, term()}
  @spec disconnect(String.t(), atom() | pid()) :: :ok | {:error, term()}
  def disconnect(address, name \\ __MODULE__) when is_binary(address) do
    case safe_call(name, {:rpc, "disconnect", %{"address" => address}}, @rpc_timeout) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
      {:error, reason, _} -> {:error, reason}
      other -> {:error, other}
    end
  end

  @spec write(String.t(), binary()) :: :ok | {:error, term()}
  @spec write(String.t(), binary(), atom() | pid()) :: :ok | {:error, term()}
  def write(address, data, name \\ __MODULE__) when is_binary(address) and is_binary(data) do
    payload = %{"address" => address, "data" => Base.encode64(data)}

    case safe_call(name, {:rpc, "write", payload}, @rpc_timeout) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
      {:error, reason, _} -> {:error, reason}
      other -> {:error, other}
    end
  end

  @doc "Deliver `{:ble_frame, frame}` notifies for this address to `pid`."
  @spec watch(String.t(), pid()) :: :ok
  @spec watch(String.t(), pid(), atom() | pid()) :: :ok
  def watch(address, pid, name \\ __MODULE__) when is_binary(address) and is_pid(pid) do
    GenServer.cast(name, {:watch, address, pid})
  end

  defp safe_call(name, request, timeout) do
    GenServer.call(name, request, timeout)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, reason -> {:error, {:exit, reason}}
  end

  @impl true
  def init(opts) do
    script =
      Keyword.get(opts, :script) ||
        System.get_env("ISTHMUS_MESHCORE_BLE_SIDECAR") ||
        Path.expand("sidecar/meshcore_ble.py", File.cwd!())

    state = %{
      port: nil,
      script: script,
      status: :starting,
      live: false,
      last_error: nil,
      pending: %{},
      watchers: %{}
    }

    {:ok, spawn_sidecar(state)}
  end

  @impl true
  def handle_call(:health, _from, state) do
    {:reply,
     %{
       status: state.status,
       live: state.live,
       script: state.script,
       last_error: state.last_error
     }, state}
  end

  def handle_call({:rpc, _type, _payload}, _from, %{status: :stub} = state) do
    {:reply, {:error, :bleak_missing}, state}
  end

  def handle_call({:rpc, _type, _payload}, _from, %{port: nil} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:rpc, type, payload}, from, %{port: port, pending: pending} = state)
      when is_port(port) do
    id = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    msg = payload |> Map.put("type", type) |> Map.put("id", id)
    true = Port.command(port, Jason.encode!(msg))
    {:noreply, %{state | pending: Map.put(pending, id, from)}}
  end

  @impl true
  def handle_cast({:watch, address, pid}, state) do
    {:noreply, put_in(state, [:watchers, address], pid)}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    state =
      case Jason.decode(data) do
        {:ok, msg} when is_map(msg) -> handle_port_msg(msg, state)
        {:ok, _} -> state
        {:error, reason} -> %{state | last_error: "ipc_decode_failed: #{inspect(reason)}"}
      end

    {:noreply, state}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    Logger.warning("MeshCore BLE sidecar exited #{code}")
    reject_pending(state.pending, {:error, :sidecar_exited})
    Process.send_after(self(), :restart, 3_000)

    {:noreply,
     %{state | port: nil, status: :crashed, live: false, pending: %{}, last_error: "exit #{code}"}}
  end

  def handle_info(:restart, state), do: {:noreply, spawn_sidecar(%{state | pending: %{}})}
  def handle_info(_msg, state), do: {:noreply, state}

  defp handle_port_msg(%{"type" => "notify", "address" => address, "data" => b64}, state) do
    case Base.decode64(to_string(b64)) do
      {:ok, frame} ->
        case Map.get(state.watchers, address) do
          pid when is_pid(pid) -> send(pid, {:ble_frame, frame})
          _ -> :ok
        end

      :error ->
        Logger.debug("MeshCore BLE notify: bad base64")
    end

    state
  end

  defp handle_port_msg(%{"type" => "disconnected", "address" => address}, state) do
    case Map.get(state.watchers, address) do
      pid when is_pid(pid) -> send(pid, {:ble_disconnected, address})
      _ -> :ok
    end

    state
  end

  defp handle_port_msg(%{"type" => "hello"} = msg, state) do
    live = msg["bleak"] == true and is_nil(msg["error"])
    status = if live, do: :live, else: :online

    if msg["error"] do
      Logger.warning("MeshCore BLE sidecar hello: #{msg["error"]}")
    else
      Logger.info("MeshCore BLE sidecar hello bleak=#{msg["bleak"]}")
    end

    %{state | status: status, live: live, last_error: msg["error"]}
  end

  defp handle_port_msg(%{"id" => id} = msg, %{pending: pending} = state) when is_binary(id) do
    case Map.pop(pending, id) do
      {nil, _} ->
        state

      {from, rest} ->
        GenServer.reply(from, normalize_rpc_reply(msg))
        %{state | pending: rest}
    end
  end

  defp handle_port_msg(%{"type" => "error"} = msg, state) do
    Logger.warning("MeshCore BLE sidecar error: #{msg["error"]}")
    %{state | last_error: msg["error"]}
  end

  defp handle_port_msg(_other, state), do: state

  defp normalize_rpc_reply(%{"ok" => false, "error" => err} = msg), do: {:error, err, msg}
  defp normalize_rpc_reply(%{"type" => "error", "error" => err}), do: {:error, err}
  defp normalize_rpc_reply(%{"ok" => true} = msg), do: {:ok, msg}
  defp normalize_rpc_reply(msg), do: {:ok, msg}

  defp spawn_sidecar(state) do
    if File.exists?(state.script) do
      case System.find_executable("python3") || System.find_executable("python") do
        nil ->
          %{state | status: :stub, live: false, last_error: "python3 not found"}

        python ->
          port =
            Port.open({:spawn_executable, python}, [
              :binary,
              :exit_status,
              :use_stdio,
              {:args, [state.script]},
              {:packet, 4}
            ])

          Logger.info("MeshCore BLE sidecar started #{state.script}")
          %{state | port: port, status: :online, last_error: nil}
      end
    else
      Logger.info("MeshCore BLE sidecar script missing at #{state.script} (stub mode)")
      %{state | status: :stub, live: false, last_error: "script missing"}
    end
  end

  defp reject_pending(pending, reason) do
    Enum.each(pending, fn {_id, from} -> GenServer.reply(from, reason) end)
  end

  defp normalize_device(dev) when is_map(dev) do
    %{
      address: to_string(dev["address"] || ""),
      name: to_string(dev["name"] || ""),
      rssi: dev["rssi"]
    }
  end
end
