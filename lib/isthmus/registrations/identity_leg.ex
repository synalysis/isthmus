defmodule Isthmus.Registrations.IdentityLeg do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "identity_legs" do
    field :network, :string
    field :role, :string, default: "proxy"
    field :identity_ref, :string
    field :public_material, :map, default: %{}
    field :encrypted_private_material, :binary
    field :presentation_cache, :map, default: %{}

    belongs_to :registration_group, Isthmus.Registrations.RegistrationGroup

    timestamps(type: :utc_datetime)
  end

  def changeset(leg, attrs) do
    leg
    |> cast(attrs, [
      :registration_group_id,
      :network,
      :role,
      :identity_ref,
      :public_material,
      :encrypted_private_material,
      :presentation_cache
    ])
    |> update_change(:identity_ref, fn
      ref when is_binary(ref) -> String.downcase(ref)
      other -> other
    end)
    |> validate_required([:network, :role, :identity_ref, :public_material])
    |> validate_inclusion(:network, ~w(nostr reticulum meshcore))
    |> validate_inclusion(:role, ~w(primary proxy member))
    |> unique_constraint([:network, :identity_ref])
  end
end
