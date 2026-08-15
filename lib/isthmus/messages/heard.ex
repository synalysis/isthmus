defmodule Isthmus.Messages.Heard do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @kinds ~w(channel group)
  @retention_seconds 7 * 24 * 60 * 60

  schema "heard_messages" do
    field :kind, :string
    field :network, :string
    field :channel_name, :string
    field :channel_idx, :integer
    field :from_ref, :string
    field :sender_name, :string
    field :body, :string
    field :external_id, :string
    field :registration_group_id, :binary_id
    field :meta, :map, default: %{}
    field :seen_at, :utc_datetime
    field :expires_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds
  def retention_seconds, do: @retention_seconds

  def changeset(row, attrs) do
    row
    |> cast(attrs, [
      :kind,
      :network,
      :channel_name,
      :channel_idx,
      :from_ref,
      :sender_name,
      :body,
      :external_id,
      :registration_group_id,
      :meta,
      :seen_at,
      :expires_at
    ])
    |> validate_required([:kind, :network, :body, :seen_at, :expires_at])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:network, ~w(meshcore meshtastic reticulum nostr agent admin))
  end
end
