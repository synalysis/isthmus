defmodule Isthmus.Repo.Migrations.CreateAnnounceSightings do
  use Ecto.Migration

  def change do
    create table(:announce_sightings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :network, :string, null: false
      add :direction, :string, null: false
      add :identity_ref, :string, null: false
      add :tunnel_id, :string
      add :hops, :integer
      add :snr, :float
      add :latency_ms, :integer
      add :path_hint, :string
      add :meta, :map, null: false, default: %{}
      add :seen_at, :utc_datetime, null: false
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:announce_sightings, [:expires_at])
    create index(:announce_sightings, [:network, :identity_ref])
    create index(:announce_sightings, [:tunnel_id])
    create index(:announce_sightings, [:seen_at])
  end
end
