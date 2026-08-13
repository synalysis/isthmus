defmodule Isthmus.Repo.Migrations.AddRadioIdsToGroupChannelLinks do
  use Ecto.Migration

  def change do
    alter table(:registration_groups) do
      add :meshcore_channel_device_id, :string
      add :meshtastic_channel_device_id, :string
    end

    drop_if_exists index(:registration_groups, [:meshcore_channel_idx],
                     name: :registration_groups_active_meshcore_channel_idx_index
                   )

    drop_if_exists index(:registration_groups, [:meshtastic_channel_idx],
                     name: :registration_groups_active_meshtastic_channel_idx_index
                   )

    create unique_index(
             :registration_groups,
             [:meshcore_channel_device_id, :meshcore_channel_idx],
             where:
               "status = 'active' AND meshcore_channel_idx IS NOT NULL AND meshcore_channel_device_id IS NOT NULL",
             name: :registration_groups_active_meshcore_channel_device_idx_index
           )

    create unique_index(
             :registration_groups,
             [:meshtastic_channel_device_id, :meshtastic_channel_idx],
             where:
               "status = 'active' AND meshtastic_channel_idx IS NOT NULL AND meshtastic_channel_device_id IS NOT NULL",
             name: :registration_groups_active_meshtastic_channel_device_idx_index
           )
  end
end
