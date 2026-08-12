defmodule Isthmus.Tunnel.Peer do
  use Ecto.Schema
  import Ecto.Changeset

  alias Isthmus.Networks.MeshCore.Channel
  alias Isthmus.Networks.Nostr

  @channel_filters ~w(all public none)
  @default_channel_filter "public"

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
    # Form-only; persisted under meta["channel_filter"].
    field :channel_filter, :string, virtual: true

    timestamps(type: :utc_datetime)
  end

  def channel_filters, do: @channel_filters
  def default_channel_filter, do: @default_channel_filter

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
      :meta,
      :channel_filter
    ])
    |> put_channel_filter_meta()
    |> normalize_peer_ref()
    |> validate_required([:name, :payload_network, :carrier_network, :peer_ref, :tunnel_id])
    |> validate_inclusion(:payload_network, ~w(reticulum meshcore nostr meshtastic))
    |> validate_inclusion(:carrier_network, ~w(reticulum meshcore nostr meshtastic))
    |> maybe_validate_channel_filter()
    |> unique_constraint(:tunnel_id)
  end

  @doc """
  MeshCore channel tunnel policy for this peer.

  * `"public"` — block only the well-known Public channel (default)
  * `"all"` — block every GRP_TXT/GRP_DATA
  * `"none"` — allow all channel traffic

  Legacy `meta["block_public_channel"]` maps to `"public"` / `"none"`.
  """
  def channel_filter(%__MODULE__{meta: meta}) when is_map(meta) do
    cond do
      is_binary(meta["channel_filter"]) and meta["channel_filter"] in @channel_filters ->
        meta["channel_filter"]

      is_binary(meta[:channel_filter]) and meta[:channel_filter] in @channel_filters ->
        meta[:channel_filter]

      Map.has_key?(meta, "block_public_channel") or Map.has_key?(meta, :block_public_channel) ->
        explicit =
          if Map.has_key?(meta, "block_public_channel"),
            do: meta["block_public_channel"],
            else: meta[:block_public_channel]

        case explicit do
          false -> "none"
          "false" -> "none"
          _ -> "public"
        end

      true ->
        @default_channel_filter
    end
  end

  def channel_filter(_), do: @default_channel_filter

  @doc "True when this peer's filter says to drop the MeshCore packet."
  def blocks_channel_packet?(%__MODULE__{} = peer, packet) when is_binary(packet) do
    case channel_filter(peer) do
      "none" -> false
      "public" -> Channel.public_group_packet?(packet)
      "all" -> Channel.group_packet?(packet)
      _ -> Channel.group_packet?(packet)
    end
  end

  def blocks_channel_packet?(_, _), do: false

  defp put_channel_filter_meta(changeset) do
    case get_change(changeset, :channel_filter) do
      nil ->
        changeset

      filter when filter in @channel_filters ->
        meta =
          (get_field(changeset, :meta) || %{})
          |> Map.put("channel_filter", filter)
          |> Map.delete("block_public_channel")

        put_change(changeset, :meta, meta)

      _ ->
        changeset
    end
  end

  defp maybe_validate_channel_filter(changeset) do
    case get_field(changeset, :channel_filter) do
      nil -> changeset
      _ -> validate_inclusion(changeset, :channel_filter, @channel_filters)
    end
  end

  @doc """
  Canonical form of a peer ref.

  Announce sightings and tunnel candidate lookups compare against a trimmed,
  downcased ref, so refs must be stored the same way or they silently never
  match. For Nostr carriers, npub is converted to 64-char hex.
  """
  def normalize_ref(ref) when is_binary(ref), do: ref |> String.trim() |> String.downcase()
  def normalize_ref(ref), do: ref

  defp normalize_peer_ref(changeset) do
    carrier = get_field(changeset, :carrier_network)
    ref = get_field(changeset, :peer_ref)

    cond do
      not is_binary(ref) ->
        changeset

      String.trim(ref) == "" ->
        put_change(changeset, :peer_ref, "")

      carrier == "nostr" ->
        case Nostr.parse_identity_ref(ref) do
          {:ok, hex, _meta} ->
            put_change(changeset, :peer_ref, hex)

          {:error, _} ->
            add_error(changeset, :peer_ref, "must be a valid npub or 64-char hex pubkey")
        end

      true ->
        put_change(changeset, :peer_ref, normalize_ref(ref))
    end
  end
end
