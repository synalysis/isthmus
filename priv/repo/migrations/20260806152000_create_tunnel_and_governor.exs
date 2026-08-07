defmodule Isthmus.Repo.Migrations.CreateTunnelAndGovernor do
  use Ecto.Migration

  def change do
    create table(:outbox_messages, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :channel, :string, null: false
      add :destination, :string, null: false
      add :payload, :binary, null: false
      add :payload_hash, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :attempts, :integer, null: false, default: 0
      add :next_attempt_at, :utc_datetime
      add :last_error, :string
      add :meta, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:outbox_messages, [:status, :next_attempt_at])
    create index(:outbox_messages, [:channel, :payload_hash])

    create table(:tunnel_peers, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :payload_network, :string, null: false
      add :carrier_network, :string, null: false
      add :peer_ref, :string, null: false
      add :tunnel_id, :string, null: false
      add :enabled, :boolean, null: false, default: true
      add :epoch, :integer, null: false, default: 0
      add :next_seq, :integer, null: false, default: 1
      add :meta, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:tunnel_peers, [:tunnel_id])
    create index(:tunnel_peers, [:payload_network, :carrier_network])

    create table(:governor_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :network, :string, null: false
      add :class, :string, null: false
      add :identity_key, :string, null: false
      add :action, :string, null: false
      add :reason, :string
      add :seen_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:governor_events, [:network, :class, :identity_key, :seen_at])
    create index(:governor_events, [:action, :seen_at])

    create table(:dedup_entries, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :dedup_key, :string, null: false
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:dedup_entries, [:dedup_key])
    create index(:dedup_entries, [:expires_at])
  end
end
