defmodule Isthmus.Networks.Reticulum.Sidecar do
  @moduledoc """
  Supervises the Python RNS/LXMF sidecar over a Port with `{:packet, 4}` JSON IPC.

  Request/response calls carry an `id` and wait for a matching reply. Unsolicited
  inbound LXMF is broadcast on PubSub `"reticulum:inbound"`.
  """
  use GenServer

  require Logger

  @call_timeout 30_000
  # Tunnel carrier sends are on the Engine tick path — keep them short so a
  # stuck Python `packet.send()` cannot take the Engine down for 30s.
  @tunnel_send_timeout 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def health do
    case safe_call(:health, 5_000) do
      {:error, _} -> %{status: :not_started, live: false}
      other -> other
    end
  end

  @doc "Live RNS instance/config/interface snapshot from the sidecar."
  def status do
    safe_rpc("status", %{})
  end

  def create_identity(opts \\ %{}) do
    safe_rpc("identity_create", Map.new(opts))
  end

  def register_identity(attrs) when is_map(attrs) do
    safe_rpc("identity_register", stringify_keys(attrs))
  end

  def announce(destination_hash) when is_binary(destination_hash) do
    safe_rpc("identity_announce", %{"destination_hash" => destination_hash})
  end

  @doc "Ask Transport for a path to a destination; reports whether Identity.recall already knows it."
  def request_path(destination_hash) when is_binary(destination_hash) do
    safe_rpc("request_path", %{"destination_hash" => destination_hash})
  end

  def path_status(destination_hash) when is_binary(destination_hash) do
    safe_rpc("path_status", %{"destination_hash" => destination_hash})
  end

  def send_packet(binary) when is_binary(binary) do
    safe_rpc("packet", %{"data" => Base.encode64(binary)})
    |> case do
      {:ok, _} -> :ok
      {:error, reason, _} -> {:error, reason}
      {:error, reason} -> {:error, reason}
      other -> other
    end
  end

  @doc """
  Send an opaque tunnel frame addressed to a peer's `isthmus.tunnel` destination.

  Returns `{:error, "no_path", _}` (and asks Reticulum for a path) until the
  peer's tunnel identity and a route are known, so callers fall back to the
  broadcast inject path. Never raises / exits the caller on timeout.
  """
  def tunnel_send(destination_hash, binary)
      when is_binary(destination_hash) and is_binary(binary) do
    safe_rpc(
      "tunnel_send",
      %{"destination_hash" => destination_hash, "data" => Base.encode64(binary)},
      @tunnel_send_timeout
    )
    |> case do
      {:ok, %{"ok" => true} = msg} -> {:ok, msg}
      {:ok, msg} -> {:error, msg["error"] || "tunnel_send_failed", msg}
      {:error, reason, msg} -> {:error, reason, msg}
      {:error, reason} -> {:error, reason}
      other -> other
    end
  end

  @doc "Our own `isthmus.tunnel` destination hash peers address frames to (addressed mode only)."
  def tunnel_status do
    safe_rpc("tunnel_status", %{})
  end

  @doc "Re-announce our tunnel destination so peers can recall the identity and learn a path."
  def tunnel_announce do
    safe_rpc("tunnel_announce", %{})
  end

  def send_lxmf(attrs) when is_map(attrs) do
    safe_rpc("lxmf_send", %{"message" => stringify_keys(attrs)})
  end

  def sync_registered_identities do
    GenServer.cast(__MODULE__, :sync_identities)
  end

  @doc """
  Kill and respawn the Python sidecar so it reloads `ISTHMUS_RNS_CONFIGDIR/config`.
  Pending RPCs are failed with `{:error, :sidecar_restarting}`.
  """
  def restart do
    safe_call(:restart, @call_timeout)
  end

  # GenServer.call exits the *caller* on timeout. Tunnel.Engine (and other
  # hot paths) must never die because the Python sidecar stalled — convert
  # exits into error tuples so send_raw can fall back to broadcast.
  defp safe_rpc(type, payload, timeout \\ @call_timeout) do
    safe_call({:rpc, type, payload}, timeout)
  end

  defp safe_call(request, timeout) do
    GenServer.call(__MODULE__, request, timeout)
  catch
    :exit, {:timeout, _} ->
      Logger.warning("RNS sidecar call timed out: #{inspect(request_label(request))}")
      {:error, :timeout}

    :exit, reason ->
      Logger.warning(
        "RNS sidecar call exited (#{inspect(request_label(request))}): #{inspect(reason)}"
      )

      {:error, {:exit, reason}}
  end

  defp request_label({:rpc, type, _}), do: type
  defp request_label(other), do: other

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

  defp handle_port_msg(%{"type" => "announce"} = msg, state) do
    _ = Isthmus.Announce.Inbound.handle_reticulum(msg)
    state
  end

  defp handle_port_msg(%{"type" => "tunnel_frame", "data" => data}, state) when is_binary(data) do
    case Base.decode64(data) do
      {:ok, binary} -> Isthmus.Tunnel.Engine.handle_inbound_frame(binary)
      :error -> Logger.debug("RNS sidecar tunnel_frame: bad base64")
    end

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
            "lxmf",
            "tunnel_destination_hash"
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
  defp normalize_rpc_reply(%{"type" => "tunnel_status"} = msg), do: {:ok, msg}
  defp normalize_rpc_reply(%{"type" => "tunnel_send_result"} = msg), do: {:ok, msg}
  defp normalize_rpc_reply(%{"type" => "tunnel_announce_result"} = msg), do: {:ok, msg}
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
