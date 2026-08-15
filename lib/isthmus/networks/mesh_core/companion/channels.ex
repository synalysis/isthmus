defmodule Isthmus.Networks.MeshCore.Companion.Channels do
  @moduledoc false

  require Logger

  alias Isthmus.Networks.MeshCore.Companion.Status
  alias Isthmus.Networks.MeshCore.Protocol

  @channel_step_ms 1_000
  @channel_sync_slack_ms 2_000

  @spec start(map(), term()) :: map()
  def start(state, from) do
    monitor =
      case from do
        {pid, _} when is_pid(pid) -> Process.monitor(pid)
        _ -> nil
      end

    deadline = state.max_channels * @channel_step_ms + @channel_sync_slack_ms
    timer = Process.send_after(self(), :channel_sync_timeout, deadline)
    queue = Enum.to_list(0..(state.max_channels - 1))

    %{
      state
      | channel_sync_from: from,
        channel_sync_monitor: monitor,
        channel_sync_queue: queue,
        channel_sync_awaiting: nil,
        channel_sync_timer: timer
    }
    |> query_next()
  end

  @spec query_next(map()) :: map()
  def query_next(%{status: :online, transport: t, transport_mod: mod} = state)
      when not is_nil(t) do
    case state.channel_sync_queue do
      [idx | rest] ->
        _ =
          mod.write(
            t,
            Protocol.encode_outbound(state.transport_kind, Protocol.get_channel_frame(idx))
          )

        Process.send_after(self(), {:channel_sync_step_timeout, idx}, @channel_step_ms)
        %{state | channel_sync_queue: rest, channel_sync_awaiting: idx}

      [] ->
        finish(state, :ok)
    end
  end

  def query_next(state), do: finish(state, {:error, :not_connected})

  @spec maybe_complete(map(), integer()) :: map()
  def maybe_complete(%{channel_sync_awaiting: idx} = state, idx) when not is_nil(idx) do
    advance(state)
  end

  def maybe_complete(state, _idx), do: state

  @spec advance(map()) :: map()
  def advance(state) do
    %{state | channel_sync_awaiting: nil}
    |> query_next()
  end

  @spec finish(map(), :ok | :timeout | {:error, term()}) :: map()
  def finish(state, reason) do
    state = Status.persist_channels(state)
    channels = Status.cached_channel_list(state)

    reply =
      case reason do
        :ok -> {:ok, channels}
        :timeout -> {:ok, channels}
        {:error, _} = err -> err
      end

    if state.channel_sync_from do
      GenServer.reply(state.channel_sync_from, reply)
    end

    if reason in [:ok, :timeout] do
      Logger.info("MeshCore channel sync done (#{length(channels)} slots)")

      Phoenix.PubSub.broadcast(
        Isthmus.PubSub,
        "meshcore:channels",
        {:meshcore_channels, channels, state.port}
      )

      send(self(), :drain_messages)
    end

    clear(state)
  end

  @spec maybe_abort(map(), term()) :: map()
  def maybe_abort(%{channel_sync_from: from} = state, reply) when not is_nil(from) do
    GenServer.reply(from, reply)
    clear(state)
  end

  def maybe_abort(state, _reply), do: clear(state)

  @spec clear(map()) :: map()
  def clear(state) do
    if state.channel_sync_monitor, do: Process.demonitor(state.channel_sync_monitor, [:flush])
    if is_reference(state.channel_sync_timer), do: Process.cancel_timer(state.channel_sync_timer)

    %{
      state
      | channel_sync_from: nil,
        channel_sync_monitor: nil,
        channel_sync_queue: [],
        channel_sync_awaiting: nil,
        channel_sync_timer: nil
    }
  end

  @spec empty_channel(integer()) :: map()
  def empty_channel(idx) do
    %{
      index: idx,
      name: "",
      secret_hex: String.duplicate("00", 16),
      empty?: true
    }
  end

  @spec missing_indices(map()) :: [integer()]
  def missing_indices(state) do
    have = MapSet.new(Map.keys(state.channels))

    remaining =
      [state.channel_sync_awaiting | state.channel_sync_queue]
      |> Enum.reject(&is_nil/1)

    0..(state.max_channels - 1)
    |> Enum.to_list()
    |> Enum.reject(&MapSet.member?(have, &1))
    |> Enum.concat(remaining)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @spec fill_missing(map(), [integer()]) :: map()
  def fill_missing(state, indices) do
    Enum.reduce(indices, state, fn idx, acc ->
      if Map.has_key?(acc.channels, idx) do
        acc
      else
        put_in(acc, [:channels, idx], empty_channel(idx))
      end
    end)
  end

  @spec parse_max_channels(binary(), pos_integer()) :: pos_integer()
  def parse_max_channels(<<fw, _max_contacts, max_channels, _::binary>>, _default)
      when fw >= 3 and max_channels > 0 do
    min(max_channels, Status.max_channel_slots())
  end

  def parse_max_channels(_, default), do: default

  @spec channel_secret_bin(term()) :: binary()
  def channel_secret_bin(nil), do: :crypto.strong_rand_bytes(16)

  def channel_secret_bin(secret) when is_binary(secret) do
    cond do
      byte_size(secret) == 16 ->
        secret

      String.match?(secret, ~r/^[0-9a-fA-F]{32}$/) ->
        {:ok, bin} = Base.decode16(secret, case: :mixed)
        bin

      true ->
        :crypto.strong_rand_bytes(16)
    end
  end

  @spec zero_secret?(binary()) :: boolean()
  def zero_secret?(bin) when is_binary(bin),
    do: byte_size(bin) > 0 and :binary.bin_to_list(bin) |> Enum.all?(&(&1 == 0))
end
