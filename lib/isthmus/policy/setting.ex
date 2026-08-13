defmodule Isthmus.Policy.Setting do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "policy_settings" do
    field :key, :string
    field :value, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{
          id: String.t() | nil,
          key: String.t() | nil,
          value: map()
        }

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:key, :value])
    |> validate_required([:key, :value])
    |> unique_constraint(:key)
  end
end
