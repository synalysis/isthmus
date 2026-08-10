defmodule Isthmus.Tunnel.Outbox do
  @moduledoc """
  Durable outbox for cross-network sends.

  Payloads are classified as `:ephemeral` (announces/adverts) or `:durable`
  (real data). Ephemeral traffic expires quickly and never enters the DLQ;
  durable traffic keeps the existing retry/DLQ behaviour and can be requeued
  when a tunnel becomes reachable again.
  """

  import Ecto.Query
  alias Isthmus.Repo
  alias Isthmus.Networks.MeshCore.Packet
  alias Isthmus.Tunnel.Frame
  alias Isthmus.Tunnel.Outbox.Class
  alias Isthmus.Tunnel.Outbox.Message

  @active_statuses ~w(pending inflight failed)
  # Announces/adverts are only worth a short hold while the carrier blips.
  @ephemeral_ttl_sec 120
  # MeshCore app resends TXT_MSG with a new attempt byte every few seconds;
  # collapse those into one outbox row while the sender is still retrying.
  @logical_retry_window_sec 180

  def ephemeral_ttl_sec, do: @ephemeral_ttl_sec

  def enqueue(channel, destination, payload, meta \\ %{}) when is_binary(payload) do
    channel = to_string(channel)
    hash = Base.encode16(Frame.hash16(payload), case: :lower)
    class = Class.classify(payload, meta)
    logical_key = Packet.logical_message_key(payload)

    meta =
      meta
      |> stringify_keys()
      |> Map.put("class", Atom.to_string(class))
      |> maybe_put_logical_key(logical_key)

    case find_active(channel, hash) do
      %Message{} = existing ->
        # Same bytes already queued or in DLQ — don't stack duplicate retries.
        {:ok, maybe_tag_class(existing, class)}

      nil ->
        case find_logical_active(channel, logical_key) do
          %Message{} = existing ->
            replace_with_latest_retry(existing, destination, payload, hash, meta)

          nil ->
            %Message{}
            |> Message.changeset(%{
              channel: channel,
              destination: destination,
              payload: payload,
              payload_hash: hash,
              status: "pending",
              next_attempt_at: DateTime.utc_now() |> DateTime.truncate(:second),
              meta: meta
            })
            |> Repo.insert()
        end
    end
  end

  def due(limit \\ 32) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Message
    |> where([m], m.status == "pending" and m.next_attempt_at <= ^now)
    |> order_by([m], asc: m.next_attempt_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def mark_inflight(%Message{} = msg) do
    msg
    |> Message.changeset(%{
      status: "inflight",
      attempts: msg.attempts + 1
    })
    |> Repo.update()
  end

  def mark_acked(%Message{} = msg) do
    msg
    |> Message.changeset(%{status: "acked"})
    |> Repo.update()
  end

  def mark_retry(%Message{} = msg, error) do
    cond do
      ephemeral_expired?(msg) or (Class.ephemeral?(msg.meta, msg.payload) and would_fail?(msg)) ->
        expire(msg, error)

      Class.durable?(msg.meta, msg.payload) ->
        # Unattended: durable traffic never parks in the DLQ. Keep retrying with
        # capped backoff until the carrier accepts it (or an operator drops it).
        delay = backoff_seconds(min(msg.attempts + 1, 8))
        next = DateTime.utc_now() |> DateTime.add(delay, :second) |> DateTime.truncate(:second)

        msg
        |> Message.changeset(%{
          status: "pending",
          attempts: msg.attempts + 1,
          next_attempt_at: next,
          last_error: truncate_error(error)
        })
        |> Repo.update()

      true ->
        delay = backoff_seconds(msg.attempts + 1)
        next = DateTime.utc_now() |> DateTime.add(delay, :second) |> DateTime.truncate(:second)
        status = if would_fail?(msg), do: "failed", else: "pending"

        result =
          msg
          |> Message.changeset(%{
            status: status,
            attempts: msg.attempts + 1,
            next_attempt_at: next,
            last_error: truncate_error(error)
          })
          |> Repo.update()

        with {:ok, %Message{status: "failed"} = failed} <- result do
          _ = drop_older_failed_duplicates(failed)
        end

        result
    end
  end

  @doc """
  Reschedule without burning an attempt (e.g. tunnel known unreachable).
  """
  def defer(%Message{} = msg, reason \\ :deferred, delay_sec \\ 30) do
    next = DateTime.utc_now() |> DateTime.add(delay_sec, :second) |> DateTime.truncate(:second)

    msg
    |> Message.changeset(%{
      status: "pending",
      next_attempt_at: next,
      last_error: truncate_error(reason)
    })
    |> Repo.update()
  end

  @doc """
  Drop an ephemeral message that exceeded its TTL (or would otherwise DLQ).

  Returns `{:ok, msg}` with status `dropped`.
  """
  def expire(%Message{} = msg, error \\ "ephemeral_expired") do
    msg
    |> Message.changeset(%{
      status: "dropped",
      attempts: msg.attempts + 1,
      last_error: truncate_error(error)
    })
    |> Repo.update()
  end

  @doc "True when an ephemeral message is older than the hold window."
  def ephemeral_expired?(%Message{} = msg) do
    Class.ephemeral?(msg.meta, msg.payload) and age_sec(msg) >= @ephemeral_ttl_sec
  end

  def stats do
    Message
    |> group_by([m], m.status)
    |> select([m], {m.status, count(m.id)})
    |> Repo.all()
    |> Map.new()
  end

  @doc "Failed / dead-letter outbox rows, newest first (one row per channel+payload)."
  def list_failed(limit \\ 50) do
    _ = collapse_failed_duplicates()

    Message
    |> where([m], m.status == "failed")
    |> order_by([m], desc: m.updated_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Re-queue a failed message for another delivery attempt."
  def retry(%Message{} = msg) do
    _ = drop_older_failed_duplicates(msg)

    msg
    |> Message.changeset(%{
      status: "pending",
      next_attempt_at: DateTime.utc_now() |> DateTime.truncate(:second),
      last_error: nil
    })
    |> Repo.update()
  end

  def retry(id) when is_binary(id) do
    case Repo.get(Message, id) do
      nil -> {:error, :not_found}
      %Message{status: "failed"} = msg -> retry(msg)
      %Message{} -> {:error, :not_failed}
    end
  end

  @doc """
  Active outbox rows for the given tunnel ids (`pending` / `inflight` / `failed`),
  grouped by tunnel_id. Newest first within each tunnel.
  """
  def list_waiting_by_tunnel(tunnel_ids, per_tunnel \\ 20)
      when is_list(tunnel_ids) and is_integer(per_tunnel) do
    tunnel_ids = Enum.filter(tunnel_ids, &(is_binary(&1) and &1 != ""))

    if tunnel_ids == [] do
      %{}
    else
      _ = collapse_logical_duplicates()
      channels = Enum.map(tunnel_ids, &"tunnel:#{&1}")

      Message
      |> where([m], m.channel in ^channels and m.status in ^@active_statuses)
      |> order_by([m], desc: m.updated_at)
      |> Repo.all()
      |> Enum.group_by(&tunnel_id_from_channel/1)
      |> Map.new(fn {tid, rows} -> {tid, Enum.take(rows, per_tunnel)} end)
    end
  end

  @doc """
  Requeue durable failed messages for a tunnel channel after it becomes reachable.

  Ephemeral rows are ignored (they should already be dropped).
  Returns the number of rows requeued.
  """
  def requeue_failed_for_tunnel(tunnel_id) when is_binary(tunnel_id) do
    channel = "tunnel:#{tunnel_id}"

    Message
    |> where([m], m.status == "failed" and m.channel == ^channel)
    |> Repo.all()
    |> Enum.filter(&Class.durable?(&1.meta, &1.payload))
    |> Enum.reduce(0, fn msg, count ->
      case retry(msg) do
        {:ok, _} -> count + 1
        _ -> count
      end
    end)
  end

  @doc "Permanently drop a message and identical active duplicates (any active status)."
  def drop(%Message{} = msg) do
    _ =
      Message
      |> where(
        [m],
        m.channel == ^msg.channel and m.payload_hash == ^msg.payload_hash and
          m.status in ^@active_statuses
      )
      |> Repo.update_all(set: [status: "dropped", updated_at: utc_now()])

    case Repo.get(Message, msg.id) do
      nil -> {:error, :not_found}
      %Message{} = updated -> {:ok, updated}
    end
  end

  def drop(id) when is_binary(id) do
    case Repo.get(Message, id) do
      nil -> {:error, :not_found}
      %Message{} = msg -> drop(msg)
    end
  end

  @doc "Schedule an active message for immediate retry (pending + due now)."
  def nudge(%Message{} = msg) do
    msg
    |> Message.changeset(%{
      status: "pending",
      next_attempt_at: utc_now(),
      last_error: nil
    })
    |> Repo.update()
  end

  def nudge(id) when is_binary(id) do
    case Repo.get(Message, id) do
      nil -> {:error, :not_found}
      %Message{status: status} = msg when status in @active_statuses -> nudge(msg)
      %Message{} -> {:error, :not_active}
    end
  end

  def get!(id), do: Repo.get!(Message, id)

  defp tunnel_id_from_channel(%{channel: channel}), do: tunnel_id_from_channel(channel)
  defp tunnel_id_from_channel("tunnel:" <> tid) when is_binary(tid), do: tid
  defp tunnel_id_from_channel(_), do: nil

  @doc false
  def collapse_failed_duplicates do
    failed =
      Message
      |> where([m], m.status == "failed")
      |> order_by([m], desc: m.updated_at)
      |> Repo.all()

    failed
    |> Enum.group_by(&{&1.channel, &1.payload_hash})
    |> Enum.each(fn {_key, [%Message{} | older]} ->
      ids = Enum.map(older, & &1.id)

      if ids != [] do
        Message
        |> where([m], m.id in ^ids)
        |> Repo.update_all(set: [status: "dropped", updated_at: utc_now()])
      end
    end)

    :ok
  end

  @doc """
  Drop older active MeshCore TXT_MSG retries that share a logical message key.

  Keeps the newest row per `{channel, logical_key}`.
  """
  def collapse_logical_duplicates do
    Message
    |> where([m], m.status in ^@active_statuses)
    |> order_by([m], desc: m.updated_at)
    |> Repo.all()
    |> Enum.group_by(fn %Message{} = m ->
      key =
        case stringify_keys(m.meta || %{}) do
          %{"logical_key" => k} when is_binary(k) and k != "" -> k
          _ -> Packet.logical_message_key(m.payload)
        end

      {m.channel, key}
    end)
    |> Enum.each(fn
      {{_channel, nil}, _} ->
        :ok

      {_key, [%Message{} | older]} ->
        ids = Enum.map(older, & &1.id)

        if ids != [] do
          Message
          |> where([m], m.id in ^ids)
          |> Repo.update_all(set: [status: "dropped", updated_at: utc_now()])
        end
    end)

    :ok
  end

  defp would_fail?(%Message{} = msg), do: msg.attempts + 1 >= 12

  defp age_sec(%Message{inserted_at: %DateTime{} = inserted}) do
    DateTime.diff(DateTime.utc_now(), inserted, :second)
  end

  defp age_sec(_), do: 0

  defp maybe_tag_class(%Message{} = msg, class) do
    meta = stringify_keys(msg.meta || %{})

    if meta["class"] == Atom.to_string(class) do
      msg
    else
      case msg
           |> Message.changeset(%{meta: Map.put(meta, "class", Atom.to_string(class))})
           |> Repo.update() do
        {:ok, updated} -> updated
        _ -> msg
      end
    end
  end

  defp maybe_put_logical_key(meta, nil), do: meta
  defp maybe_put_logical_key(meta, key) when is_binary(key), do: Map.put(meta, "logical_key", key)

  defp find_active(channel, hash) do
    Message
    |> where(
      [m],
      m.channel == ^channel and m.payload_hash == ^hash and m.status in ^@active_statuses
    )
    |> order_by([m], desc: m.updated_at)
    |> limit(1)
    |> Repo.one()
  end

  defp find_logical_active(_channel, nil), do: nil

  defp find_logical_active(channel, logical_key) when is_binary(logical_key) do
    Message
    |> where([m], m.channel == ^channel and m.status in ^@active_statuses)
    |> order_by([m], desc: m.updated_at)
    |> Repo.all()
    |> Enum.find(fn %Message{} = m ->
      within_retry_window?(m) and
        (stringify_keys(m.meta || %{})["logical_key"] == logical_key or
           Packet.logical_message_key(m.payload) == logical_key)
    end)
  end

  defp within_retry_window?(%Message{updated_at: %DateTime{} = at}) do
    DateTime.diff(DateTime.utc_now(), at, :second) <= @logical_retry_window_sec
  end

  defp within_retry_window?(%Message{inserted_at: %DateTime{} = at}) do
    DateTime.diff(DateTime.utc_now(), at, :second) <= @logical_retry_window_sec
  end

  defp within_retry_window?(_), do: false

  defp replace_with_latest_retry(%Message{} = existing, destination, payload, hash, meta) do
    # Prefer the newest MeshCore attempt bytes so a far-side ACK matches what
    # the sender is currently waiting for. Leave attempt counters alone — those
    # track tunnel carrier tries, not MeshCore app retries.
    status = if existing.status == "inflight", do: "inflight", else: "pending"

    existing
    |> Message.changeset(%{
      destination: destination,
      payload: payload,
      payload_hash: hash,
      status: status,
      meta: meta,
      next_attempt_at: existing.next_attempt_at || utc_now(),
      last_error: existing.last_error
    })
    |> Repo.update()
  end

  defp drop_older_failed_duplicates(%Message{} = msg) do
    Message
    |> where(
      [m],
      m.status == "failed" and m.channel == ^msg.channel and m.payload_hash == ^msg.payload_hash and
        m.id != ^msg.id
    )
    |> Repo.update_all(set: [status: "dropped", updated_at: utc_now()])
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp backoff_seconds(attempt) do
    # jittered exponential: 2^n with cap, plus 0..attempt seconds
    base = min(Bitwise.bsl(1, min(attempt, 8)), 300)
    base + :rand.uniform(max(attempt, 1))
  end

  defp truncate_error(err) when is_binary(err), do: String.slice(err, 0, 240)

  # Errors are often tuples/atoms (e.g. `{:governor, :dedup}`), which don't
  # implement String.Chars — inspect them so mark_retry never crashes the caller.
  defp truncate_error(err), do: err |> inspect() |> String.slice(0, 240)
end
