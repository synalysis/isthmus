defmodule Isthmus.Tunnel.Outbox do
  @moduledoc "Durable outbox for cross-network sends."

  import Ecto.Query
  alias Isthmus.Repo
  alias Isthmus.Tunnel.Frame
  alias Isthmus.Tunnel.Outbox.Message

  def enqueue(channel, destination, payload, meta \\ %{}) when is_binary(payload) do
    hash = Base.encode16(Frame.hash16(payload), case: :lower)

    %Message{}
    |> Message.changeset(%{
      channel: to_string(channel),
      destination: destination,
      payload: payload,
      payload_hash: hash,
      status: "pending",
      next_attempt_at: DateTime.utc_now() |> DateTime.truncate(:second),
      meta: meta
    })
    |> Repo.insert()
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
    delay = backoff_seconds(msg.attempts + 1)
    next = DateTime.utc_now() |> DateTime.add(delay, :second) |> DateTime.truncate(:second)

    status = if msg.attempts + 1 >= 12, do: "failed", else: "pending"

    msg
    |> Message.changeset(%{
      status: status,
      attempts: msg.attempts + 1,
      next_attempt_at: next,
      last_error: truncate_error(error)
    })
    |> Repo.update()
  end

  def stats do
    Message
    |> group_by([m], m.status)
    |> select([m], {m.status, count(m.id)})
    |> Repo.all()
    |> Map.new()
  end

  @doc "Failed / dead-letter outbox rows, newest first."
  def list_failed(limit \\ 50) do
    Message
    |> where([m], m.status == "failed")
    |> order_by([m], desc: m.updated_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Re-queue a failed message for another delivery attempt."
  def retry(%Message{} = msg) do
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

  @doc "Permanently drop a failed message from the DLQ."
  def drop(%Message{} = msg) do
    msg
    |> Message.changeset(%{status: "dropped"})
    |> Repo.update()
  end

  def drop(id) when is_binary(id) do
    case Repo.get(Message, id) do
      nil -> {:error, :not_found}
      %Message{} = msg -> drop(msg)
    end
  end

  def get!(id), do: Repo.get!(Message, id)

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
