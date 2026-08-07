defmodule Isthmus.Announce.Sighting do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @retention_seconds 86_400

  schema "announce_sightings" do
    field :network, :string
    field :direction, :string
    field :identity_ref, :string
    field :tunnel_id, :string
    field :hops, :integer
    field :snr, :float
    field :latency_ms, :integer
    field :path_hint, :string
    field :meta, :map, default: %{}
    field :seen_at, :utc_datetime
    field :expires_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def retention_seconds, do: @retention_seconds

  def changeset(row, attrs) do
    row
    |> cast(attrs, [
      :network,
      :direction,
      :identity_ref,
      :tunnel_id,
      :hops,
      :snr,
      :latency_ms,
      :path_hint,
      :meta,
      :seen_at,
      :expires_at
    ])
    |> validate_required([:network, :direction, :identity_ref, :seen_at, :expires_at])
    |> validate_inclusion(:direction, ~w(in out))
    |> normalize_identity_ref()
  end

  defp normalize_identity_ref(changeset) do
    case get_change(changeset, :identity_ref) || get_field(changeset, :identity_ref) do
      nil -> changeset
      ref -> put_change(changeset, :identity_ref, String.downcase(ref))
    end
  end
end
