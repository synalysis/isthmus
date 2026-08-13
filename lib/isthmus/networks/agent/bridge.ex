defmodule Isthmus.Networks.Agent.Bridge do
  @moduledoc """
  ACP client for group-attached agents.

  Spawns the configured agent command (default `agent acp`) and keeps one
  session per agent identity. Group traffic is queued and prompted; the
  collected `agent_message_chunk` text is published on `"agent:inbound"`.
  """
  use GenServer

  require Logger

  @reconnect_ms 15_000

  @type health :: %{
          :status => atom(),
          :last_error => String.t() | nil,
          optional(:detail) => String.t(),
          optional(:command) => String.t(),
          optional(:sessions) => non_neg_integer(),
          optional(:queued) => non_neg_integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec health() :: health()
  def health do
    GenServer.call(__MODULE__, :health, 1_000)
  catch
    :exit, _ -> %{status: :not_started, last_error: "ACP bridge not started"}
  end

  @spec prompt(String.t(), String.t()) :: :ok | {:error, atom()}
  @spec prompt(String.t(), String.t(), map()) :: :ok | {:error, atom()}
  def prompt(identity_ref, text, meta \\ %{})
      when is_binary(identity_ref) and is_binary(text) do
    GenServer.call(__MODULE__, {:enqueue, identity_ref, text, meta}, 5_000)
  catch
    :exit, _ -> {:error, :not_started}
  end

  @spec reconnect() :: {:ok, health()} | {:error, :not_started}
  def reconnect do
    GenServer.call(__MODULE__, :reconnect, 15_000)
  catch
    :exit, _ -> {:error, :not_started}
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       client: nil,
       status: :disconnected,
       last_error: nil,
       sessions: %{},
       chunks: %{},
       queue: :queue.new(),
       busy: false
     }, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state), do: {:noreply, maybe_connect(state)}

  @impl true
  def handle_call(:health, _from, state) do
    {:reply, health_map(state), state}
  end

  def handle_call(:reconnect, _from, state) do
    state = state |> drop_client() |> maybe_connect()
    {:reply, {:ok, health_map(state)}, state}
  end

  def handle_call({:enqueue, _ref, _text, _meta}, _from, %{status: status} = state)
      when status != :online do
    {:reply, {:error, :not_connected}, state}
  end

  def handle_call({:enqueue, ref, text, meta}, _from, state) do
    state = %{state | queue: :queue.in({ref, text, stringify_meta(meta)}, state.queue)}
    {:reply, :ok, pump(state)}
  end

  @impl true
  def handle_info(:reconnect, state), do: {:noreply, maybe_connect(state)}

  def handle_info({:EXIT, pid, reason}, %{client: pid} = state) when is_pid(pid) do
    Logger.warning("ACP client exited: #{inspect(reason)}")
    Process.send_after(self(), :reconnect, @reconnect_ms)

    {:noreply,
     %{
       state
       | client: nil,
         status: :error,
         last_error: inspect(reason),
         sessions: %{},
         chunks: %{},
         busy: false
     }}
  end

  def handle_info({:acp_session_update, sid, update}, state) when is_map(update) do
    {:noreply, collect_chunk(state, sid, update)}
  end

  def handle_info(
        {:acp_prompt_done, ref, result},
        %{busy: {busy_ref, identity_ref, _meta}} = state
      )
      when ref == busy_ref do
    sid = session_of(identity_ref, state)

    case result do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("ACP prompt failed for #{identity_ref}: #{inspect(reason)}")
    end

    text = reply_text(result, Map.get(state.chunks, sid, ""))

    if text != "", do: publish_reply(identity_ref, text)

    {:noreply,
     pump(%{
       state
       | busy: false,
         chunks: Map.delete(state.chunks, sid)
     })}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp drop_client(%{client: nil} = state) do
    %{state | sessions: %{}, chunks: %{}, busy: false, queue: :queue.new()}
  end

  defp drop_client(%{client: pid} = state) when is_pid(pid) do
    Process.unlink(pid)

    if Process.alive?(pid) do
      try do
        GenServer.stop(pid, :shutdown, 5_000)
      catch
        :exit, _ -> :ok
      end
    end

    drop_client(%{state | client: nil, status: :disconnected, last_error: nil})
  end

  defp maybe_connect(%{client: client} = state) when not is_nil(client), do: state

  defp maybe_connect(state) do
    opts = Application.get_env(:isthmus, Isthmus.Networks.Agent, [])

    cond do
      Keyword.get(opts, :enabled, true) == false ->
        %{state | status: :disabled, last_error: "ACP agent disabled"}

      command(opts) == [] ->
        %{
          state
          | status: :disabled,
            last_error: "no ACP command (set Admin → ACP or ISTHMUS_ACP_COMMAND)"
        }

      true ->
        start_client(state, opts)
    end
  end

  defp start_client(state, opts) do
    case ExMCP.ACP.start_client(
           command: command(opts),
           handler: Isthmus.Networks.Agent.Handler,
           event_listener: self(),
           capabilities: %{},
           client_info: %{"name" => "isthmus", "version" => "0.1.0"}
         ) do
      {:ok, client} ->
        Logger.info("ACP agent online via #{inspect(command(opts))}")
        pump(%{state | client: client, status: :online, last_error: nil})

      {:error, reason} ->
        Logger.warning("ACP agent connect failed: #{inspect(reason)}")
        Process.send_after(self(), :reconnect, @reconnect_ms)
        %{state | status: :error, last_error: inspect(reason)}
    end
  end

  defp pump(%{busy: busy} = state) when busy != false, do: state

  defp pump(%{status: :online, client: client} = state) when not is_nil(client) do
    case :queue.out(state.queue) do
      {:empty, _} ->
        state

      {{:value, {ref, text, meta}}, queue} ->
        case ensure_session(state, ref) do
          {:ok, sid, state} ->
            task_ref = make_ref()
            parent = self()

            timeout = prompt_timeout()

            _ =
              Task.start(fn ->
                result =
                  try do
                    ExMCP.ACP.Client.prompt(client, sid, text, timeout: timeout)
                  catch
                    kind, reason -> {:error, {kind, reason}}
                  end

                send(parent, {:acp_prompt_done, task_ref, result})
              end)

            %{
              state
              | queue: queue,
                busy: {task_ref, ref, meta},
                chunks: Map.put(state.chunks, sid, "")
            }

          {:error, reason} ->
            Logger.warning("ACP session failed for #{ref}: #{inspect(reason)}")
            pump(%{state | queue: queue, last_error: inspect(reason)})
        end
    end
  end

  defp pump(state), do: state

  defp ensure_session(state, ref) do
    case Map.fetch(state.sessions, ref) do
      {:ok, sid} ->
        {:ok, sid, state}

      :error ->
        cwd = session_cwd()

        case ExMCP.ACP.Client.new_session(state.client, cwd) do
          {:ok, %{"sessionId" => sid}} ->
            {:ok, sid, %{state | sessions: Map.put(state.sessions, ref, sid)}}

          {:ok, %{sessionId: sid}} ->
            {:ok, sid, %{state | sessions: Map.put(state.sessions, ref, sid)}}

          other ->
            {:error, other}
        end
    end
  end

  defp collect_chunk(state, sid, %{"sessionUpdate" => "agent_message_chunk"} = update) do
    piece =
      case update do
        %{"content" => %{"text" => text}} when is_binary(text) -> text
        %{"text" => text} when is_binary(text) -> text
        _ -> ""
      end

    %{state | chunks: Map.update(state.chunks, sid, piece, &(&1 <> piece))}
  end

  defp collect_chunk(state, _sid, _update), do: state

  defp publish_reply(from_ref, body) do
    Phoenix.PubSub.broadcast(
      Isthmus.PubSub,
      "agent:inbound",
      {:agent_message,
       %{
         from_ref: from_ref,
         body: body,
         meta: %{}
       }}
    )
  end

  defp session_of(ref, state), do: Map.get(state.sessions, ref)

  defp command(opts) do
    case Keyword.get(opts, :command, ["agent", "acp"]) do
      list when is_list(list) -> Enum.filter(list, &(is_binary(&1) and &1 != ""))
      bin when is_binary(bin) -> String.split(bin)
      _ -> []
    end
  end

  defp reply_text({:ok, result}, buffered) when is_map(result) do
    streamed = if is_binary(buffered), do: String.trim(buffered), else: ""

    case result["text"] || result[:text] do
      text when is_binary(text) and text != "" -> String.trim(text)
      _ -> streamed
    end
  end

  defp reply_text(_result, buffered) when is_binary(buffered), do: String.trim(buffered)
  defp reply_text(_, _), do: ""

  defp prompt_timeout do
    opts = Application.get_env(:isthmus, Isthmus.Networks.Agent, [])
    Keyword.get(opts, :prompt_timeout_ms, 120_000)
  end

  defp session_cwd do
    opts = Application.get_env(:isthmus, Isthmus.Networks.Agent, [])

    case Keyword.get(opts, :cwd) do
      cwd when is_binary(cwd) and cwd != "" -> cwd
      _ -> File.cwd!()
    end
  end

  defp stringify_meta(meta) when is_map(meta) do
    Map.new(meta, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp stringify_meta(_), do: %{}

  defp health_map(state) do
    opts = Application.get_env(:isthmus, Isthmus.Networks.Agent, [])

    %{
      status: state.status,
      last_error: state.last_error,
      detail: "Agent Client Protocol",
      command: Enum.join(command(opts), " "),
      sessions: map_size(state.sessions),
      queued: :queue.len(state.queue)
    }
  end
end
