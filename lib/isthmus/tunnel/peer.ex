defmodule Isthmus.Tunnel.Peer do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "tunnel_peers" do
    field :name, :string
    field :payload_network, :string
    field :carrier_network, :string
    field :peer_ref, :string
    field :tunnel_id, :string
    field :enabled, :boolean, default: true
    field :epoch, :integer, default: 0
    field :next_seq, :integer, default: 1
    field :meta, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  def changeset(peer, attrs) do
    peer
    |> cast(attrs, [
      :name,
      :payload_network,
      :carrier_network,
      :peer_ref,
      :tunnel_id,
      :enabled,
      :epoch,
      :next_seq,
      :meta
    ])
    |> update_change(:peer_ref, &normalize_ref/1)
    |> validate_required([:name, :payload_network, :carrier_network, :peer_ref, :tunnel_id])
    |> validate_inclusion(:payload_network, ~w(reticulum meshcore nostr meshtastic))
    |> validate_inclusion(:carrier_network, ~w(reticulum meshcore nostr meshtastic))
    |> unique_constraint(:tunnel_id)
  end

  @doc """
  Canonical form of a peer ref.

  Announce sightings and tunnel candidate lookups compare against a trimmed,
  downcased ref, so refs must be stored the same way or they silently never
  match.
  """
  def normalize_ref(ref) when is_binary(ref), do: ref |> String.trim() |> String.downcase()
  def normalize_ref(ref), do: ref
end
