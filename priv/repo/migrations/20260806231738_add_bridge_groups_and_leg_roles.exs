defmodule Isthmus.Repo.Migrations.AddBridgeGroupsAndLegRoles do
  use Ecto.Migration

  def change do
    alter table(:registration_groups) do
      add :kind, :string, null: false, default: "registration"
    end

    create index(:registration_groups, [:kind])
  end
end
