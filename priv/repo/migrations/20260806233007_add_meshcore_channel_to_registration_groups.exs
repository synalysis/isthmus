defmodule Isthmus.Repo.Migrations.AddMeshcoreChannelToRegistrationGroups do
  use Ecto.Migration

  def change do
    alter table(:registration_groups) do
      add :meshcore_channel_idx, :integer
      add :meshcore_channel_secret_enc, :binary
    end

    create unique_index(:registration_groups, [:meshcore_channel_idx],
             where: "status = 'active' AND meshcore_channel_idx IS NOT NULL",
             name: :registration_groups_active_meshcore_channel_idx_index
           )
  end
end
