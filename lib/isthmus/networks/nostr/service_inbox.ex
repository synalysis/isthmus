defmodule Isthmus.Networks.Nostr.ServiceInbox do
  @moduledoc """
  In-memory mailbox for DMs addressed to the Isthmus **service** Nostr identity
  (`ISTHMUS_NOSTR_NSEC`).

  These messages are **not** routed to groups — per-group proxy npubs own that.
  Operators can inspect them on the Nostr admin page.
  """
  use GenServer

  @topic "nostr:service_inbox"
  @max 100

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "PubSub topic for live inbox updates."
  def topic, do: @topic

  @doc """
  Ensure the named process is running.

  Needed after code reload when the Networks supervisor was started before
  this child existed — a full app restart is still preferred.
  """
  def ensure_started do
    case Process.whereis(__MODULE__) do
      pid when is_pid(pid) ->
        :ok

      nil ->
        case start_link([]) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Record a decrypted DM to the service identity.

  Accepts a `Gateway.Message` or a map with `:from_ref`, `:body`, `:external_id`, `:meta`.
  """
  def record(msg) do
    case ensure_started() do
      :ok -> GenServer.cast(__MODULE__, {:record, normalize(msg)})
      _ -> :ok
    end
  end

  def list(limit \\ 50) when is_integer(limit) and limit > 0 do
    case ensure_started() do
      :ok -> GenServer.call(__MODULE__, {:list, limit})
      _ -> []
    end
  catch
    :exit, _ -> []
  end

  def clear do
    case ensure_started() do
      :ok -> GenServer.call(__MODULE__, :clear)
      _ -> :ok
    end
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(_opts), do: {:ok, %{messages: []}}

  @impl true
  def handle_cast({:record, entry}, state) do
    messages = Enum.take([entry | state.messages], @max)
    Phoenix.PubSub.broadcast(Isthmus.PubSub, @topic, {:service_dm, entry})
    {:noreply, %{state | messages: messages}}
  end

  @impl true
  def handle_call({:list, limit}, _from, state) do
    {:reply, Enum.take(state.messages, limit), state}
  end

  def handle_call(:clear, _from, _state) do
    {:reply, :ok, %{messages: []}}
  end

  defp normalize(%Isthmus.Gateway.Message{} = msg) do
    normalize(%{
      from_ref: msg.from_ref,
      body: msg.body,
      external_id: msg.external_id,
      meta: msg.meta || %{}
    })
  end

  defp normalize(attrs) when is_map(attrs) do
    meta = attrs[:meta] || attrs["meta"] || %{}
    body = attrs[:body] || attrs["body"] || ""

    %{
      id: attrs[:external_id] || attrs["external_id"] || random_id(),
      from_ref: downcase(attrs[:from_ref] || attrs["from_ref"]),
      body: body,
      subject: meta["subject"] || meta[:subject],
      kind: meta["kind"] || meta[:kind],
      received_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }
  end

  defp downcase(v) when is_binary(v), do: String.downcase(v)
  defp downcase(_), do: nil

  defp random_id, do: "svc-" <> Integer.to_string(System.unique_integer([:positive]))
end
