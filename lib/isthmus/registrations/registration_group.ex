defmodule Isthmus.Registrations.RegistrationGroup do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "registration_groups" do
    field :owner_pubkey_hex, :string
    field :display_name, :string
    field :status, :string, default: "active"
    field :created_by, :string, default: "self_service"
    field :kind, :string, default: "registration"
    field :meshcore_channel_idx, :integer
    field :meshcore_channel_secret_enc, :binary
    field :meshcore_channel_device_id, :string
    field :meshtastic_channel_idx, :integer
    field :meshtastic_channel_psk_enc, :binary
    field :meshtastic_channel_device_id, :string

    has_many :legs, Isthmus.Registrations.IdentityLeg
    has_many :radio_channels, Isthmus.Registrations.GroupRadioChannel

    timestamps(type: :utc_datetime)
  end

  def changeset(group, attrs) do
    group
    |> cast(attrs, [
      :owner_pubkey_hex,
      :display_name,
      :status,
      :created_by,
      :kind,
      :meshcore_channel_idx,
      :meshcore_channel_secret_enc,
      :meshcore_channel_device_id,
      :meshtastic_channel_idx,
      :meshtastic_channel_psk_enc,
      :meshtastic_channel_device_id
    ])
    |> update_change(:owner_pubkey_hex, &String.downcase/1)
    |> validate_required([:owner_pubkey_hex, :status, :created_by, :kind])
    |> validate_inclusion(:status, ~w(pending active revoked))
    |> validate_inclusion(:created_by, ~w(self_service admin))
    |> validate_inclusion(:kind, ~w(registration bridge))
    |> validate_number(:meshcore_channel_idx,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 7
    )
    |> validate_number(:meshtastic_channel_idx,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 7
    )
  end
end
