defmodule Isthmus.Repo.Migrations.AddMeshtasticChannelToRegistrationGroups do
  use Ecto.Migration

  def change do
    alter table(:registration_groups) do
      add :meshtastic_channel_idx, :integer
      add :meshtastic_channel_psk_enc, :binary
    end

    create unique_index(:registration_groups, [:meshtastic_channel_idx],
             where: "status = 'active' AND meshtastic_channel_idx IS NOT NULL",
             name: :registration_groups_active_meshtastic_channel_idx_index
           )
  end
end
