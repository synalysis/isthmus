defmodule Isthmus.Repo.Migrations.CreateHeardMessages do
  use Ecto.Migration

  def change do
    create table(:heard_messages, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :kind, :string, null: false
      add :network, :string, null: false
      add :channel_name, :string
      add :channel_idx, :integer
      add :from_ref, :string
      add :sender_name, :string
      add :body, :string, null: false
      add :external_id, :string
      add :registration_group_id, :binary_id
      add :meta, :map, null: false, default: %{}
      add :seen_at, :utc_datetime, null: false
      add :expires_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:heard_messages, [:expires_at])
    create index(:heard_messages, [:seen_at])
    create index(:heard_messages, [:network, :kind])
    create index(:heard_messages, [:external_id])
  end
end
