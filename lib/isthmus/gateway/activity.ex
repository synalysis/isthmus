defmodule Isthmus.Gateway.Activity do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "gateway_messages" do
    field :direction, :string
    field :from_network, :string
    field :to_network, :string
    field :from_ref, :string
    field :to_ref, :string
    field :body, :string
    field :status, :string, default: "accepted"
    field :error, :string
    field :external_id, :string
    field :meta, :map, default: %{}
    field :registration_group_id, :binary_id

    timestamps(type: :utc_datetime)
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, [
      :direction,
      :from_network,
      :to_network,
      :from_ref,
      :to_ref,
      :body,
      :status,
      :error,
      :external_id,
      :meta,
      :registration_group_id
    ])
    |> validate_required([:direction, :from_network, :to_network, :status])
    |> validate_inclusion(:direction, ~w(in out bridge))
    |> validate_inclusion(:status, ~w(accepted delivered failed dropped))
    |> put_default_body()
  end

  # Content is intentionally omitted from the activity log; keep a non-null column.
  defp put_default_body(changeset) do
    case get_field(changeset, :body) do
      nil -> put_change(changeset, :body, "")
      _ -> changeset
    end
  end
end
