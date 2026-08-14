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
    attrs =
      attrs
      |> stringify_keys()
      |> resolve_tunnel_secrets(fn ->
        Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
      end)

    %Peer{}
    |> Peer.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Deterministic `tunnel_id` (32-char lowercase hex) from a human-friendly shared
  code. Both endpoints of a tunnel enter the same code — comparison is trimmed
  and case-insensitive — so they land on the same `tunnel_id`, which is the only
  thing inbound frames are demuxed by (the carrier address is not used).

  Stored as hex because the inbound path compares `Base.encode16(frame.tunnel_id)`
  against `peer.tunnel_id`.
  """
  def tunnel_id_from_code(code) when is_binary(code) do
    normalized = code |> String.trim() |> String.downcase()

    :crypto.hash(:sha256, "isthmus-tunnel|" <> normalized)
    |> binary_part(0, 16)
    |> Base.encode16(case: :lower)
  end

  @doc "32-byte HMAC key derived from a pairing / auth secret."
  def mac_key_from_code(code) when is_binary(code) do
    normalized = code |> String.trim() |> String.downcase()
    :crypto.hash(:sha256, "isthmus-tunnel-mac|" <> normalized)
  end

  @doc "Legacy HMAC key when only the public tunnel id is shared."
  def mac_key_from_tunnel_id(id) when is_binary(id) do
    :crypto.hash(:sha256, "isthmus-tunnel-mac-id|" <> String.downcase(id))
  end

  @doc "HMAC key for encoding/verifying ISTH frames for this peer."
  def mac_key(%Peer{} = peer) do
    meta = peer.meta || %{}
    hex = meta["mac_key_hex"] || meta[:mac_key_hex]

    case is_binary(hex) && Base.decode16(hex, case: :mixed) do
      {:ok, key} when byte_size(key) == 32 -> key
      _ -> mac_key_from_tunnel_id(peer.tunnel_id)
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  # Resolve tunnel_id + MAC key. `pairing_code` / `auth_secret` are virtual and
  # never persisted; the derived mac_key_hex lives under meta.
  defp resolve_tunnel_secrets(attrs, fallback) when is_function(fallback, 0) do
    pairing = attrs["pairing_code"]
    auth_secret = attrs["auth_secret"]

    tunnel_id =
      cond do
        present?(attrs["tunnel_id"]) -> attrs["tunnel_id"]
        present?(pairing) -> tunnel_id_from_code(pairing)
        true -> fallback.()
      end

    mac_hex =
      cond do
        present?(pairing) ->
          Base.encode16(mac_key_from_code(pairing), case: :lower)

        present?(auth_secret) ->
          Base.encode16(mac_key_from_code(auth_secret), case: :lower)

        true ->
          Base.encode16(mac_key_from_tunnel_id(tunnel_id), case: :lower)
      end

    meta =
      case attrs["meta"] do
        map when is_map(map) -> stringify_keys(map)
        _ -> %{}
      end
      |> Map.put("mac_key_hex", mac_hex)

    attrs
    |> Map.put("tunnel_id", tunnel_id)
    |> Map.put("meta", meta)
    |> Map.delete("pairing_code")
    |> Map.delete("auth_secret")
  end

  def update_peer(%Peer{} = peer, attrs) do
    raw = stringify_keys(attrs)
    rotating? = present?(raw["pairing_code"]) or present?(raw["auth_secret"])

    attrs =
      raw
      |> Map.put_new("meta", peer.meta || %{})
      |> resolve_tunnel_secrets(fn -> peer.tunnel_id end)

    attrs =
      if rotating? do
        attrs
      else
        stored = (peer.meta || %{})["mac_key_hex"]
        meta = attrs["meta"] || %{}

        meta =
          if is_binary(stored) and stored != "",
            do: Map.put(meta, "mac_key_hex", stored),
            else: meta

        Map.put(attrs, "meta", meta)
      end

    peer |> Peer.changeset(attrs) |> Repo.update()
  end

  def delete_peer(%Peer{} = peer), do: Repo.delete(peer)

  def change_peer(%Peer{} = peer, attrs \\ %{}) do
    peer
    |> Map.put(:channel_filter, Peer.channel_filter(peer))
    |> Peer.changeset(attrs)
  end

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

  Ephemeral traffic (announces / MeshCore adverts) is skipped when the tunnel is
  known unreachable so it does not pile up while the peer is offline.
  """
  def send_payload(%Peer{} = peer, payload, meta \\ %{}) when is_binary(payload) do
    meta =
      Map.merge(stringify_keys(meta), %{
        "payload_network" => peer.payload_network,
        "carrier_network" => peer.carrier_network,
        "tunnel_id" => peer.tunnel_id,
        "seq" => peer.next_seq
      })

    class = Isthmus.Tunnel.Outbox.Class.classify(payload, meta)

    if class == :ephemeral and tunnel_unreachable?(peer.tunnel_id) do
      {:ok, :skipped_unreachable}
    else
      Outbox.enqueue("tunnel:#{peer.tunnel_id}", peer.peer_ref, payload, meta)
    end
  end

  @doc "Enqueue via the best peer for peer_ref (least hops / lowest latency)."
  def send_payload_best(peer_ref, payload, meta \\ %{}) when is_binary(payload) do
    case best_peer(peer_ref) do
      nil -> {:error, :no_tunnel_peer}
      %Peer{} = peer -> send_payload(peer, payload, meta)
    end
  end

  defp tunnel_unreachable?(tunnel_id) when is_binary(tunnel_id) do
    case Map.get(Isthmus.Tunnel.Engine.health(), tunnel_id) do
      %{status: :unreachable} -> true
      _ -> false
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
