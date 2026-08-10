defmodule Isthmus.Tunnel.Bridge do
  @moduledoc """
  Island traffic producer for opaque tunnels.

  * `forward_packet/3` — wrap local same-protocol packets into the tunnel outbox
    for every enabled peer whose `payload_network` matches.
  * `forward_announce/3` — fan announce/advert intent as tunnel **control** frames
    so remote Isthmus nodes re-announce on their island (without looping).
  """

  require Logger

  alias Isthmus.Announce.Dedup
  alias Isthmus.Announce.Governor
  alias Isthmus.Announce.Inbound
  alias Isthmus.Networks.MeshCore.Advert
  alias Isthmus.Networks.MeshCore.Packet
  alias Isthmus.Tunnel
  alias Isthmus.Tunnel.{Frame, Peer}
  alias Isthmus.Repo

  import Ecto.Query

  @packet_dedup_ttl 30
  @announce_dedup_ttl 60

  @doc """
  Enqueue an opaque island packet onto matching tunnel peers.

  Skips when `opts[:from_tunnel]` is set (loop prevention) or the packet was
  recently forwarded (hash dedup). MeshCore ADVERT packets are also recorded as
  announce sightings so they appear on the Adverts page.
  """
  def forward_packet(payload_network, packet, opts \\ %{})

  def forward_packet(payload_network, packet, opts)
      when is_binary(payload_network) and is_binary(packet) and byte_size(packet) > 0 do
    opts = Map.new(opts)

    if truthy?(opts[:from_tunnel] || opts["from_tunnel"]) do
      :ok
    else
      # Sightings are independent of tunnel forward dedup — an advert may still
      # need to show on Adverts even when we collapse a re-flood for the outbox.
      _ = maybe_record_meshcore_advert(payload_network, packet)

      if recently_seen_packet?(payload_network, packet) do
        :ok
      else
        peers = peers_for_payload(payload_network)

        Enum.each(peers, fn peer ->
          case Tunnel.send_payload(peer, packet, %{
                 "kind" => "data",
                 "source" => opts[:source] || opts["source"] || "island"
               }) do
            {:ok, _} -> :ok
            {:error, reason} -> Logger.debug("tunnel forward_packet failed: #{inspect(reason)}")
          end
        end)

        :ok
      end
    end
  end

  def forward_packet(_, _, _), do: :ok

  @doc """
  Fan an announce/advert control message to tunnels for `payload_network`.

  Remote Engine applies `Networks.announce/3` with `from_tunnel: true`.
  """
  def forward_announce(payload_network, identity_ref, meta \\ %{})

  def forward_announce(payload_network, identity_ref, meta)
      when is_binary(payload_network) and is_binary(identity_ref) and identity_ref != "" do
    meta = Map.new(meta)

    if truthy?(meta[:from_tunnel] || meta["from_tunnel"]) do
      :ok
    else
      dedup_key = "tunnel_ann|#{payload_network}|#{String.downcase(identity_ref)}"

      if Dedup.seen?(dedup_key, @announce_dedup_ttl) do
        :ok
      else
        payload =
          Jason.encode!(%{
            "v" => 1,
            "op" => "announce",
            "network" => to_string(payload_network),
            "ref" => String.downcase(identity_ref),
            "meta" => stringify_meta(meta)
          })

        peers_for_payload(payload_network)
        |> Enum.each(fn peer ->
          case Governor.allow?(:tunnel_control, peer.carrier_network, peer.tunnel_id) do
            :ok -> enqueue_control(peer, payload)
            {:drop, _} -> :ok
          end
        end)

        :ok
      end
    end
  end

  def forward_announce(_, _, _), do: :ok

  @doc """
  Record `packet` as already bridged.

  Call this before injecting a tunnel-delivered packet back onto an island, so
  that if the island echoes it to us we don't send it back down the tunnel.

  Returns `:ok` the first time a path-insensitive packet hash is seen, or
  `:duplicate` if it was already marked (e.g. arrived earlier via another
  redundant tunnel). Callers should skip a second island inject on `:duplicate`.
  """
  def mark_forwarded(packet) when is_binary(packet) and byte_size(packet) > 0 do
    if recently_seen_packet?("meshcore", packet), do: :duplicate, else: :ok
  end

  def mark_forwarded(_), do: :ok

  @doc "Enabled peers that carry this payload network."
  def peers_for_payload(payload_network) when is_binary(payload_network) do
    net = to_string(payload_network)

    Peer
    |> where([p], p.enabled == true and p.payload_network == ^net)
    |> order_by([p], asc: p.name)
    |> Repo.all()
  end

  defp enqueue_control(%Peer{} = peer, payload) when is_binary(payload) do
    case Tunnel.send_payload(peer, payload, %{"kind" => "control"}) do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.debug("tunnel control enqueue failed: #{inspect(reason)}")
    end
  end

  # Dedup key must be path-INSENSITIVE for MeshCore so a flood that reaches us
  # via multiple tunnels in a cyclic topology (A–B–C triangle) collapses to one
  # forward, and so an injected packet's own echo (with an extra bridge path
  # hash appended by the local repeater) is recognized. This mirrors MeshCore's
  # `wasSeen` which hashes `type ‖ payload` and ignores the accumulating path.
  defp recently_seen_packet?(payload_network, packet) do
    Dedup.seen?(dedup_key(payload_network, packet), @packet_dedup_ttl)
  end

  defp maybe_record_meshcore_advert("meshcore", packet) do
    with {:ok, decoded} <- Packet.decode(packet),
         true <- decoded.payload_type == Packet.type_advert(),
         {:ok, %{public_key: pub, name: name}} <- Advert.parse_payload(decoded.payload) do
      hex = Base.encode16(pub, case: :lower)
      Inbound.record("meshcore", hex, name, "bridge_advert")
    else
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  defp maybe_record_meshcore_advert(_, _), do: :ok

  defp dedup_key("meshcore", packet) do
    case Packet.decode(packet) do
      {:ok, decoded} ->
        "tunnel_pkt|meshcore|" <> Base.encode16(Packet.packet_hash(decoded), case: :lower)

      _ ->
        fallback_dedup_key(packet)
    end
  end

  defp dedup_key(_payload_network, packet), do: fallback_dedup_key(packet)

  defp fallback_dedup_key(packet) do
    "tunnel_pkt|" <> Base.encode16(Frame.hash16(packet), case: :lower)
  end

  defp truthy?(v), do: v in [true, "true", "1", 1]

  defp stringify_meta(meta) when is_map(meta) do
    Map.new(meta, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
