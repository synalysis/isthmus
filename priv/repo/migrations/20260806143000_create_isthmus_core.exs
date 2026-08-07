defmodule Isthmus.Repo.Migrations.CreateIsthmusCore do
  use Ecto.Migration

  def change do
    create table(:policy_settings, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :key, :string, null: false
      add :value, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:policy_settings, [:key])

    create table(:admin_pubkeys, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :pubkey_hex, :string, null: false
      add :npub, :string, null: false
      add :label, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:admin_pubkeys, [:pubkey_hex])
    create unique_index(:admin_pubkeys, [:npub])

    create table(:nostr_relays, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :url, :string, null: false
      add :enabled, :boolean, null: false, default: true
      add :priority, :integer, null: false, default: 100
      add :read, :boolean, null: false, default: true
      add :write, :boolean, null: false, default: true
      add :auth_secret, :string

      timestamps(type: :utc_datetime)
    end

    create unique_index(:nostr_relays, [:url])

    create table(:registration_groups, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :owner_pubkey_hex, :string, null: false
      add :display_name, :string
      add :status, :string, null: false, default: "active"
      add :created_by, :string, null: false, default: "self_service"

      timestamps(type: :utc_datetime)
    end

    create index(:registration_groups, [:owner_pubkey_hex])
    create index(:registration_groups, [:status])

    create table(:identity_legs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :registration_group_id,
          references(:registration_groups, type: :binary_id, on_delete: :delete_all), null: false

      add :network, :string, null: false
      add :role, :string, null: false, default: "proxy"
      add :identity_ref, :string, null: false
      add :public_material, :map, null: false, default: %{}
      add :encrypted_private_material, :binary
      add :presentation_cache, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:identity_legs, [:registration_group_id])
    create unique_index(:identity_legs, [:network, :identity_ref])
  end
end
