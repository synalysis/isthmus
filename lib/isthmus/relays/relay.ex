defmodule Isthmus.Relays.Relay do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "nostr_relays" do
    field :url, :string
    field :enabled, :boolean, default: true
    field :priority, :integer, default: 100
    field :read, :boolean, default: true
    field :write, :boolean, default: true
    field :auth_secret, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(relay, attrs) do
    relay
    |> cast(attrs, [:url, :enabled, :priority, :read, :write, :auth_secret])
    |> validate_required([:url])
    |> validate_format(:url, ~r/^wss?:\/\//i, message: "must start with ws:// or wss://")
    |> unique_constraint(:url)
  end
end
