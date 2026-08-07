defmodule Isthmus.Tunnel.Outbox.Message do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "outbox_messages" do
    field :channel, :string
    field :destination, :string
    field :payload, :binary
    field :payload_hash, :string
    field :status, :string, default: "pending"
    field :attempts, :integer, default: 0
    field :next_attempt_at, :utc_datetime
    field :last_error, :string
    field :meta, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  def changeset(msg, attrs) do
    msg
    |> cast(attrs, [
      :channel,
      :destination,
      :payload,
      :payload_hash,
      :status,
      :attempts,
      :next_attempt_at,
      :last_error,
      :meta
    ])
    |> validate_required([:channel, :destination, :payload, :payload_hash, :status])
    |> validate_inclusion(:status, ~w(pending inflight acked failed dropped))
  end
end
