defmodule Isthmus.Registrations.GroupRadioChannel do
  @moduledoc """
  A private radio channel slot linked to a group.

  Slot numbers are local to each radio. The same group may be linked to
  several Meshtastic or MeshCore companions, each on its own device id + slot.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "group_radio_channels" do
    field :network, :string
    field :device_id, :string
    field :channel_idx, :integer
    field :secret_enc, :binary

    belongs_to :registration_group, Isthmus.Registrations.RegistrationGroup

    timestamps(type: :utc_datetime)
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [
      :registration_group_id,
      :network,
      :device_id,
      :channel_idx,
      :secret_enc
    ])
    |> update_change(:device_id, fn
      id when is_binary(id) ->
        trimmed = id |> String.trim() |> String.trim_leading("!") |> String.downcase()
        if trimmed == "", do: nil, else: trimmed

      other ->
        other
    end)
    |> validate_required([:network, :channel_idx, :secret_enc])
    |> validate_inclusion(:network, ~w(meshcore meshtastic))
    |> validate_number(:channel_idx, greater_than_or_equal_to: 0, less_than_or_equal_to: 7)
    |> unique_constraint([:network, :device_id, :channel_idx],
      name: :group_radio_channels_network_device_idx_index
    )
    |> unique_constraint([:network, :channel_idx],
      name: :group_radio_channels_unscoped_network_idx_index
    )
    |> unique_constraint([:registration_group_id, :network, :device_id],
      name: :group_radio_channels_group_network_device_index
    )
  end
end
