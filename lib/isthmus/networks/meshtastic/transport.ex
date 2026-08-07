defmodule Isthmus.Networks.Meshtastic.Transport do
  @moduledoc """
  In-process Meshtastic transport stub for tunnel `send_raw/2`.

  Queues outbound opaque frames and accepts synthetic inbound frames until a
  real serial/MQTT radio client is wired (see `docs/guides/meshtastic_adapter.md`).
  """
  use GenServer

  @max_queue 256

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def health, do: GenServer.call(__MODULE__, :health)

  def send_raw(payload, opts \\ %{}) when is_binary(payload) do
    GenServer.call(__MODULE__, {:send_raw, payload, Map.new(opts)})
  end

  @doc "Inject a frame as if received from the radio (tests / future radio client)."
  def inject_inbound(payload, opts \\ %{}) when is_binary(payload) do
    GenServer.cast(__MODULE__, {:inbound, payload, Map.new(opts)})
  end

  def drain_outbound(limit \\ 32) do
    GenServer.call(__MODULE__, {:drain, limit})
  end

  @impl true
  def init(_opts) do
    {:ok, %{outbound: :queue.new(), sent: 0, received: 0, last_error: nil}}
  end

  @impl true
  def handle_call(:health, _from, state) do
    {:reply,
     %{
       status: :stub,
       detail: "In-memory Meshtastic transport — bind a radio client later",
       outbound_queued: :queue.len(state.outbound),
       sent: state.sent,
       received: state.received,
       last_error: state.last_error
     }, state}
  end

  def handle_call({:send_raw, payload, opts}, _from, state) do
    if :queue.len(state.outbound) >= @max_queue do
      {:reply, {:error, :queue_full}, %{state | last_error: :queue_full}}
    else
      item = %{payload: payload, opts: opts, at: System.system_time(:second)}
      outbound = :queue.in(item, state.outbound)

      Phoenix.PubSub.broadcast(
        Isthmus.PubSub,
        "meshtastic:raw",
        {:meshtastic_raw_out, item}
      )

      {:reply, :ok, %{state | outbound: outbound, sent: state.sent + 1}}
    end
  end

  def handle_call({:drain, limit}, _from, state) do
    {items, outbound} = take(state.outbound, limit, [])
    {:reply, Enum.reverse(items), %{state | outbound: outbound}}
  end

  @impl true
  def handle_cast({:inbound, payload, opts}, state) do
    Isthmus.Tunnel.Engine.ingest_carrier_blob(
      "meshtastic",
      payload,
      Map.put(opts, :source, "meshtastic")
    )

    Phoenix.PubSub.broadcast(
      Isthmus.PubSub,
      "meshtastic:raw",
      {:meshtastic_raw_in, %{payload: payload, opts: opts}}
    )

    {:noreply, %{state | received: state.received + 1}}
  end

  defp take(queue, 0, acc), do: {acc, queue}

  defp take(queue, n, acc) when n > 0 do
    case :queue.out(queue) do
      {{:value, item}, rest} -> take(rest, n - 1, [item | acc])
      {:empty, _} -> {acc, queue}
    end
  end
end
