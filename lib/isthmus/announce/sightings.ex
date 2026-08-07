defmodule Isthmus.Announce.Sightings do
  @moduledoc """
  24-hour announce/path sightings for tunnel routing and admin visibility.
  """
  import Ecto.Query
  alias Isthmus.Announce.Sighting
  alias Isthmus.Repo
  alias Isthmus.Tunnel.Peer

  @default_limit 50

  @doc """
  Record a sighting. Sets `expires_at` to seen_at + 24h unless provided.
  Links `tunnel_id` when identity_ref matches an enabled tunnel peer's peer_ref.
  """
  def record(attrs) when is_map(attrs) do
    attrs = Map.new(attrs)

    seen_at =
      attrs[:seen_at] || attrs["seen_at"] || DateTime.utc_now() |> DateTime.truncate(:second)

    expires_at =
      attrs[:expires_at] || attrs["expires_at"] ||
        DateTime.add(seen_at, Sighting.retention_seconds(), :second)

    identity_ref = normalize_ref(attrs[:identity_ref] || attrs["identity_ref"])
    network = to_string(attrs[:network] || attrs["network"])
    direction = to_string(attrs[:direction] || attrs["direction"] || "in")

    tunnel_id =
      attrs[:tunnel_id] || attrs["tunnel_id"] ||
        lookup_tunnel_id(identity_ref)

    meta = attrs[:meta] || attrs["meta"] || %{}

    %Sighting{}
    |> Sighting.changeset(%{
      network: network,
      direction: direction,
      identity_ref: identity_ref,
      tunnel_id: tunnel_id,
      hops: attrs[:hops] || attrs["hops"],
      snr: attrs[:snr] || attrs["snr"],
      latency_ms: attrs[:latency_ms] || attrs["latency_ms"],
      path_hint: attrs[:path_hint] || attrs["path_hint"],
      meta: meta,
      seen_at: seen_at,
      expires_at: expires_at
    })
    |> Repo.insert()
  end

  @doc "Recent sightings, newest first."
  def list_recent(limit \\ @default_limit) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Sighting
    |> where([s], s.expires_at > ^now)
    |> order_by([s], desc: s.seen_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Best recent sighting for an identity on a network (if any)."
  def best_for(network, identity_ref) do
    identity_ref = normalize_ref(identity_ref)
    network = to_string(network)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Sighting
    |> where(
      [s],
      s.network == ^network and s.identity_ref == ^identity_ref and s.expires_at > ^now
    )
    |> order_by([s], desc: s.seen_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc "Latest sighting linked to a tunnel_id."
  def latest_for_tunnel(tunnel_id) when is_binary(tunnel_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Sighting
    |> where([s], s.tunnel_id == ^tunnel_id and s.expires_at > ^now)
    |> order_by([s], desc: s.seen_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc "Delete expired rows."
  def purge_expired do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      Sighting
      |> where([s], s.expires_at <= ^now)
      |> Repo.delete_all()

    count
  end

  defp lookup_tunnel_id(identity_ref) when is_binary(identity_ref) do
    from(p in Peer,
      where: p.enabled == true and p.peer_ref == ^identity_ref,
      order_by: [desc: p.updated_at],
      limit: 1,
      select: p.tunnel_id
    )
    |> Repo.one()
  end

  defp lookup_tunnel_id(_), do: nil

  defp normalize_ref(ref) when is_binary(ref), do: String.downcase(String.trim(ref))
  defp normalize_ref(_), do: ""
end
