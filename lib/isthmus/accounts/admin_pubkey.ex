defmodule Isthmus.Accounts.AdminPubkey do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "admin_pubkeys" do
    field :pubkey_hex, :string
    field :npub, :string
    field :label, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(admin, attrs) do
    admin
    |> cast(attrs, [:pubkey_hex, :npub, :label])
    |> update_change(:pubkey_hex, &String.downcase/1)
    |> validate_required([:pubkey_hex, :npub])
    |> validate_length(:pubkey_hex, is: 64)
    |> unique_constraint(:pubkey_hex)
    |> unique_constraint(:npub)
  end
end
