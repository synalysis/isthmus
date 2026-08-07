defmodule Isthmus.Repo.Migrations.CreateGatewayMessages do
  use Ecto.Migration

  def change do
    create table(:gateway_messages, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :registration_group_id,
          references(:registration_groups, type: :binary_id, on_delete: :nilify_all)

      add :direction, :string, null: false
      add :from_network, :string, null: false
      add :to_network, :string, null: false
      add :from_ref, :string
      add :to_ref, :string
      add :body, :string, null: false
      add :status, :string, null: false, default: "accepted"
      add :error, :string
      add :external_id, :string
      add :meta, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:gateway_messages, [:inserted_at])
    create index(:gateway_messages, [:status])
    create index(:gateway_messages, [:registration_group_id])
  end
end
