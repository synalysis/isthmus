defmodule Isthmus.Networks.Reticulum.Sidecar do
  @moduledoc """
  Supervises the Python RNS/LXMF sidecar over a Port with `{:packet, 4}` JSON IPC.

  Request/response calls carry an `id` and wait for a matching reply. Unsolicited
  inbound LXMF is broadcast on PubSub `"reticulum:inbound"`.
  """
  use GenServer

  require Logger

  @call_timeout 30_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def health, do: GenServer.call(__MODULE__, :health)

  @doc "Live RNS instance/config/interface snapshot from the sidecar."
  def status do
    GenServer.call(__MODULE__, {:rpc, "status", %{}}, @call_timeout)
  end

  def create_identity(opts \\ %{}) do
    GenServer.call(__MODULE__, {:rpc, "identity_create", Map.new(opts)}, @call_timeout)
  end

  def register_identity(attrs) when is_map(attrs) do
    GenServer.call(
      __MODULE__,
      {:rpc, "identity_register", stringify_keys(attrs)},
      @call_timeout
    )
  end

  def announce(destination_hash) when is_binary(destination_hash) do
    GenServer.call(
      __MODULE__,
      {:rpc, "identity_announce", %{"destination_hash" => destination_hash}},
      @call_timeout
    )
  end

  @doc "Ask Transport for a path to a destination; reports whether Identity.recall already knows it."
  def request_path(destination_hash) when is_binary(destination_hash) do
    GenServer.call(
      __MODULE__,
      {:rpc, "request_path", %{"destination_hash" => destination_hash}},
      @call_timeout
    )
  end

  def path_status(destination_hash) when is_binary(destination_hash) do
    GenServer.call(
      __MODULE__,
      {:rpc, "path_status", %{"destination_hash" => destination_hash}},
      @call_timeout
    )
  end

  def send_packet(binary) when is_binary(binary) do
    GenServer.call(
      __MODULE__,
      {:rpc, "packet", %{"data" => Base.encode64(binary)}},
      @call_timeout
    )
    |> case do
      {:ok, _} -> :ok
      {:error, reason, _} -> {:error, reason}
      {:error, reason} -> {:error, reason}
      other -> other
    end
  end

  def send_lxmf(attrs) when is_map(attrs) do
    GenServer.call(
      __MODULE__,
      {:rpc, "lxmf_send", %{"message" => stringify_keys(attrs)}},
      @call_timeout
    )
  end

  def sync_registered_identities do
    GenServer.cast(__MODULE__, :sync_identities)
  end

  @doc """
  Kill and respawn the Python sidecar so it reloads `ISTHMUS_RNS_CONFIGDIR/config`.
  Pending RPCs are failed with `{:error, :sidecar_restarting}`.
  """
  def restart do
    GenServer.call(__MODULE__, :restart, @call_timeout)
  end

  @impl true
  def init(_opts) do
    script =
      System.get_env("ISTHMUS_RNS_SIDECAR") ||
        Path.expand("sidecar/rns_sidecar.py", File.cwd!())

    configdir =
      System.get_env("ISTHMUS_RNS_CONFIGDIR") ||
        Path.expand("~/.isthmus/reticulum")

    env = [
      {~c"ISTHMUS_RNS_CONFIGDIR", String.to_charlist(configdir)},
      {~c"ISTHMUS_RNS_STORAGE",
       String.to_charlist(
         System.get_env("ISTHMUS_RNS_STORAGE") || Path.join(configdir, "lxmf_storage")
       )},
      {~c"ISTHMUS_RNS_NODE_NAME",
       String.to_charlist(System.get_env("ISTHMUS_RNS_NODE_NAME") || "isthmus")},
      {~c"ISTHMUS_RNS_LOGLEVEL",
       String.to_charlist(System.get_env("ISTHMUS_RNS_LOGLEVEL") || "3")}
    ]

    state = %{
      port: nil,
      script: script,
      configdir: configdir,
      status: :starting,
      live: false,
      last_error: nil,
      meta: %{},
      pending: %{},
      env: env
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
       configdir: state.configdir,
       last_error: state.last_error,
       meta: state.meta
     }, state}
  end

  def handle_call({:rpc, _type, _payload}, _from, %{status: :stub} = state) do
    {:reply, {:error, :stub_mode}, state}
  end

  def handle_call({:rpc, _type, _payload}, _from, %{port: nil} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:rpc, type, payload}, from, %{port: port, pending: pending} = state)
      when is_port(port) do
    id = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    msg = payload |> Map.put("type", type) |> Map.put("id", id)
    true = Port.command(port, Jason.encode!(msg))
    {:noreply, %{state | pending: Map.put(pending, id, {from, type})}}
  end

  def handle_call(:restart, _from, state) do
    reject_pending(state.pending, {:error, :sidecar_restarting})
    state = close_port(%{state | pending: %{}})
    {:reply, :ok, spawn_sidecar(state)}
  end

  @impl true
  def handle_cast(:sync_identities, state) do
    Task.start(fn -> do_sync_identities() end)
    {:noreply, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    state =
      case Jason.decode(data) do
        {:ok, msg} when is_map(msg) -> handle_port_msg(msg, state)
        _ -> state
      end

    {:noreply, state}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    Logger.warning("RNS sidecar exited #{code}")
    reject_pending(state.pending, {:error, :sidecar_exited})
    Process.send_after(self(), :restart, 3_000)

    {:noreply,
     %{state | port: nil, status: :crashed, live: false, pending: %{}, last_error: "exit #{code}"}}
  end

  def handle_info(:restart, state), do: {:noreply, spawn_sidecar(%{state | pending: %{}})}

  def handle_info(:sync_after_hello, state) do
    Task.start(fn -> do_sync_identities() end)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp handle_port_msg(%{"type" => "lxmf", "message" => message}, state) do
    Phoenix.PubSub.broadcast(Isthmus.PubSub, "reticulum:inbound", {:lxmf, message})
    state
  end

  defp handle_port_msg(%{"type" => "hello"} = msg, state) do
    live = msg["rns"] == true and msg["lxmf"] == true and is_nil(msg["error"])
    status = if live, do: :live, else: :online

    if msg["error"] do
      Logger.warning("RNS sidecar hello error: #{msg["error"]}")
    else
      Logger.info("RNS sidecar hello live=#{live} configdir=#{msg["configdir"]}")
    end

    if live, do: Process.send_after(self(), :sync_after_hello, 500)

    %{
      state
      | status: status,
        live: live,
        last_error: msg["error"],
        meta:
          Map.take(msg, [
            "configdir",
            "storagepath",
            "rns_version",
            "lxmf_version",
            "rns",
            "lxmf"
          ])
    }
  end

  defp handle_port_msg(%{"id" => id} = msg, %{pending: pending} = state) when is_binary(id) do
    case Map.pop(pending, id) do
      {nil, _} ->
        Logger.debug("RNS sidecar unmatched reply: #{inspect(msg["type"])}")
        state

      {{from, _type}, rest} ->
        GenServer.reply(from, normalize_rpc_reply(msg))
        %{state | pending: rest}
    end
  end

  defp handle_port_msg(%{"type" => "error"} = msg, state) do
    Logger.warning("RNS sidecar error: #{msg["error"]}")
    %{state | last_error: msg["error"]}
  end

  defp handle_port_msg(other, state) do
    Logger.debug("RNS sidecar: #{inspect(other)}")
    state
  end

  defp normalize_rpc_reply(%{"ok" => false, "error" => err} = msg), do: {:error, err, msg}
  defp normalize_rpc_reply(%{"type" => "error", "error" => err}), do: {:error, err}
  defp normalize_rpc_reply(%{"ok" => true} = msg), do: {:ok, msg}
  defp normalize_rpc_reply(%{"type" => "lxmf_sent"} = msg), do: {:ok, msg}
  defp normalize_rpc_reply(%{"type" => "identity_create_result"} = msg), do: {:ok, msg}
  defp normalize_rpc_reply(%{"type" => "pong"} = msg), do: {:ok, msg}
  defp normalize_rpc_reply(%{"type" => "status"} = msg), do: {:ok, msg}
  defp normalize_rpc_reply(%{"type" => "path_status"} = msg), do: {:ok, msg}
  defp normalize_rpc_reply(%{"type" => "request_path_result"} = msg), do: {:ok, msg}
  defp normalize_rpc_reply(msg), do: {:ok, msg}

  defp close_port(%{port: port} = state) when is_port(port) do
    # RNS multiprocessing leaves child interpreters; kill the tree, not only the parent.
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} when is_integer(os_pid) and os_pid > 1 ->
        _ =
          System.cmd("pkill", ["-TERM", "-P", Integer.to_string(os_pid)], stderr_to_stdout: true)

        _ = System.cmd("kill", ["-TERM", Integer.to_string(os_pid)], stderr_to_stdout: true)
        Process.sleep(300)

        _ =
          System.cmd("pkill", ["-KILL", "-P", Integer.to_string(os_pid)], stderr_to_stdout: true)

        _ = System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)

      _ ->
        :ok
    end

    catch_port_close(port)
    %{state | port: nil, status: :restarting, live: false, last_error: nil}
  end

  defp close_port(state), do: %{state | port: nil, status: :restarting, live: false}

  defp catch_port_close(port) do
    Port.close(port)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp spawn_sidecar(state) do
    if File.exists?(state.script) do
      case System.find_executable("python3") || System.find_executable("python") do
        nil ->
          %{state | status: :stub, live: false, last_error: "python3 not found"}

        python ->
          File.mkdir_p!(state.configdir)

          port =
            Port.open({:spawn_executable, python}, [
              :binary,
              :exit_status,
              :use_stdio,
              :stderr_to_stdout,
              {:args, [state.script]},
              {:packet, 4},
              {:env, state.env}
            ])

          Logger.info("RNS sidecar started #{state.script}")
          %{state | port: port, status: :online, last_error: nil}
      end
    else
      Logger.info("RNS sidecar script missing at #{state.script} (stub mode)")
      %{state | status: :stub, live: false, last_error: "script missing"}
    end
  end

  defp do_sync_identities do
    # Application-owned process; skip under test SQL sandbox.
    if Application.get_env(:isthmus, :rns_sync_on_boot, true) == false do
      :ok
    else
      alias Isthmus.Registrations

      Registrations.list_all()
      |> Enum.filter(&(&1.status == "active"))
      |> Enum.each(fn group ->
        # Register every Isthmus-owned RNS proxy. Preferring primary/member would skip
        # bridge proxies (the LXMF inbox MeshChatX messages).
        group.legs
        |> Enum.filter(&(&1.network == "reticulum" and &1.role == "proxy"))
        |> Enum.each(fn leg ->
          case Registrations.ensure_reticulum_ready(leg) do
            {:ok, ready} ->
              _ = announce(ready.identity_ref)

            {:error, reason} ->
              Logger.warning(
                "RNS identity sync skipped for #{leg.identity_ref}: #{inspect(reason)}"
              )
          end
        end)
      end)
    end
  rescue
    e -> Logger.warning("RNS identity sync failed: #{inspect(e)}")
  catch
    :exit, reason -> Logger.warning("RNS identity sync exit: #{inspect(reason)}")
  end

  defp reject_pending(pending, reason) do
    Enum.each(pending, fn {_id, {from, _}} -> GenServer.reply(from, reason) end)
  end

  defp stringify_keys(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
