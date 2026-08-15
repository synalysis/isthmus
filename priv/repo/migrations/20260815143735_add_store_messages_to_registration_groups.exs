defmodule Isthmus.Repo.Migrations.AddStoreMessagesToRegistrationGroups do
  use Ecto.Migration

  def change do
    alter table(:registration_groups) do
      add :store_messages, :boolean, null: false, default: false
    end
  end
end
