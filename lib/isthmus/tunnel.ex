defmodule Isthmus.Tunnel do
  @moduledoc """
  Tunnel peer management and send API.

  Opaque island bridging: same-protocol packets are framed (ISTH) and carried over
  another network. See `Isthmus.Tunnel.Bridge` for auto-forward / announce fan-out
  and `Isthmus.Tunnel.Engine` for drain, reassembly, and inject.
  """

  import Ecto.Query
  alias Isthmus.Announce.Sightings
  alias Isthmus.Repo
  alias Isthmus.Tunnel.{Frame, Outbox, Peer}

  @missing_hops_penalty 1_000
  @failure_penalty 500

  def list_peers do
    Peer |> order_by([p], asc: p.name) |> Repo.all()
  end

  def get_peer!(id), do: Repo.get!(Peer, id)

  def create_peer(attrs) do
    tunnel_id =
      Map.get(attrs, :tunnel_id) || Map.get(attrs, "tunnel_id") ||
        Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

    attrs = Map.put(attrs, "tunnel_id", tunnel_id) |> stringify_keys()

    %Peer{}
    |> Peer.changeset(attrs)
    |> Repo.insert()
  end

  def update_peer(%Peer{} = peer, attrs) do
    peer |> Peer.changeset(attrs) |> Repo.update()
  end

  def change_peer(%Peer{} = peer, attrs \\ %{}), do: Peer.changeset(peer, attrs)

  def bump_seq(%Peer{} = peer) do
    peer
    |> Peer.changeset(%{next_seq: peer.next_seq + 1})
    |> Repo.update()
  end

  @doc "Enabled peers with the same normalized peer_ref."
  def candidates(peer_ref) when is_binary(peer_ref) do
    ref = normalize_ref(peer_ref)

    Peer
    |> where([p], p.enabled == true and p.peer_ref == ^ref)
    |> order_by([p], asc: p.name)
    |> Repo.all()
  end

  @doc "Score a peer for routing (lower is better)."
  def score_peer(%Peer{} = peer) do
    sighting = Sightings.latest_for_tunnel(peer.tunnel_id)
    failures = recent_failure_count(peer.tunnel_id)

    hops_score =
      case sighting do
        %{hops: hops} when is_integer(hops) -> hops
        _ -> @missing_hops_penalty
      end

    latency_score =
      case sighting do
        %{latency_ms: ms} when is_integer(ms) -> ms
        _ -> 10_000
      end

    age_penalty =
      case sighting do
        %{seen_at: %DateTime{} = seen} ->
          DateTime.diff(DateTime.utc_now(), seen, :second)

        _ ->
          86_400
      end

    hops_score * 10_000 + latency_score + div(age_penalty, 60) + failures * @failure_penalty
  end

  @doc "Best enabled peer among those sharing peer_ref."
  def best_peer(peer_ref) when is_binary(peer_ref) do
    case candidates(peer_ref) do
      [] -> nil
      [only] -> only
      peers -> Enum.min_by(peers, &score_peer/1)
    end
  end

  @doc """
  Enqueue opaque payload for a tunnel peer (fragmented later by Engine against carrier MTU).
  """
  def send_payload(%Peer{} = peer, payload, meta \\ %{}) when is_binary(payload) do
    Outbox.enqueue(
      "tunnel:#{peer.tunnel_id}",
      peer.peer_ref,
      payload,
      Map.merge(meta, %{
        "payload_network" => peer.payload_network,
        "carrier_network" => peer.carrier_network,
        "tunnel_id" => peer.tunnel_id,
        "seq" => peer.next_seq
      })
    )
  end

  @doc "Enqueue via the best peer for peer_ref (least hops / lowest latency)."
  def send_payload_best(peer_ref, payload, meta \\ %{}) when is_binary(payload) do
    case best_peer(peer_ref) do
      nil -> {:error, :no_tunnel_peer}
      %Peer{} = peer -> send_payload(peer, payload, meta)
    end
  end

  @doc "Routing explanation for admin UI."
  def routing_choice(peer_ref) when is_binary(peer_ref) do
    peers = candidates(peer_ref)
    best = best_peer(peer_ref)

    %{
      peer_ref: normalize_ref(peer_ref),
      candidates: peers,
      best: best,
      scores:
        Map.new(peers, fn p ->
          {p.tunnel_id,
           %{score: score_peer(p), sighting: Sightings.latest_for_tunnel(p.tunnel_id)}}
        end)
    }
  end

  def encode_fragments(%Peer{} = peer, payload, mtu) do
    tid = Frame.tunnel_id_from_string(peer.tunnel_id)
    Frame.fragment(tid, peer.next_seq, payload, mtu)
  end

  defp recent_failure_count(tunnel_id) do
    alias Isthmus.Tunnel.Outbox.Message

    since = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

    Message
    |> where(
      [m],
      m.channel == ^"tunnel:#{tunnel_id}" and m.status == "failed" and m.updated_at >= ^since
    )
    |> Repo.aggregate(:count, :id)
  end

  defp normalize_ref(ref) when is_binary(ref), do: String.downcase(String.trim(ref))

  defp stringify_keys(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
