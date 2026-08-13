defmodule Isthmus.Repo.Migrations.CreateGroupRadioChannels do
  use Ecto.Migration

  def up do
    create table(:group_radio_channels, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :registration_group_id,
          references(:registration_groups, type: :binary_id, on_delete: :delete_all),
          null: false

      add :network, :string, null: false
      add :device_id, :string
      add :channel_idx, :integer, null: false
      add :secret_enc, :binary

      timestamps(type: :utc_datetime)
    end

    create index(:group_radio_channels, [:registration_group_id])

    create unique_index(:group_radio_channels, [:network, :device_id, :channel_idx],
             where: "device_id IS NOT NULL",
             name: :group_radio_channels_network_device_idx_index
           )

    create unique_index(:group_radio_channels, [:network, :channel_idx],
             where: "device_id IS NULL",
             name: :group_radio_channels_unscoped_network_idx_index
           )

    create unique_index(:group_radio_channels, [:registration_group_id, :network, :device_id],
             where: "device_id IS NOT NULL",
             name: :group_radio_channels_group_network_device_index
           )

    flush()
    copy_existing_links()
  end

  def down do
    drop table(:group_radio_channels)
  end

  defp copy_existing_links do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows =
      repo().query!(
        """
        SELECT id, meshcore_channel_idx, meshcore_channel_secret_enc, meshcore_channel_device_id,
               meshtastic_channel_idx, meshtastic_channel_psk_enc, meshtastic_channel_device_id
        FROM registration_groups
        """,
        []
      ).rows

    inserts =
      Enum.flat_map(rows, fn [id, mc_idx, mc_enc, mc_dev, mt_idx, mt_enc, mt_dev] ->
        Enum.reject(
          [
            link_row(id, "meshcore", mc_idx, mc_enc, mc_dev, now),
            link_row(id, "meshtastic", mt_idx, mt_enc, mt_dev, now)
          ],
          &is_nil/1
        )
      end)

    if inserts != [] do
      repo().insert_all("group_radio_channels", inserts)
    end
  end

  defp link_row(_id, _network, nil, _enc, _dev, _now), do: nil
  defp link_row(_id, _network, _idx, nil, _dev, _now), do: nil

  defp link_row(id, network, idx, enc, dev, now) do
    %{
      id: Ecto.UUID.generate(),
      registration_group_id: id,
      network: network,
      device_id: dev,
      channel_idx: idx,
      secret_enc: enc,
      inserted_at: now,
      updated_at: now
    }
  end
end
