defmodule Isthmus.Tunnel.Engine do
  @moduledoc """
  Drains the durable outbox, fragments payloads for the carrier MTU, and
  dispatches via network adapters. Reassembly buffer kept in-process.
  """
  use GenServer

  require Logger

  alias Isthmus.Announce.Sightings
  alias Isthmus.Announce.Governor
  alias Isthmus.Networks
  alias Isthmus.Tunnel
  alias Isthmus.Tunnel.{Frame, Outbox, Peer}
  alias Isthmus.Repo

  @tick_ms 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def enqueue_to_peer(peer_id, payload) when is_binary(payload) do
    peer = Tunnel.get_peer!(peer_id)
    Tunnel.send_payload(peer, payload)
  end

  def handle_inbound_frame(binary) when is_binary(binary) do
    GenServer.cast(__MODULE__, {:inbound, binary})
  end

  @impl true
  def init(_opts) do
    Sightings.purge_expired()

    state = %{
      reassembly: %{},
      pending_acks: %{},
      stats: %{sent: 0, acked: 0, dropped: 0, reassembled: 0}
    }

    schedule_tick()
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    Sightings.purge_expired()
    state = drain_outbox(state)
    schedule_tick()
    {:noreply, state}
  end

  @impl true
  def handle_cast({:inbound, binary}, state) do
    state =
      case Frame.decode(binary) do
        {:ok, frame, _rest} -> ingest_frame(frame, state)
        {:error, _} -> state
      end

    {:noreply, state}
  end

  def handle_cast({:ack, tunnel_id, seq}, %{pending_acks: pending} = state) do
    record_ack_latency(tunnel_id, seq, pending)

    import Ecto.Query
    alias Isthmus.Tunnel.Outbox.Message

    Message
    |> where([m], m.channel == ^"tunnel:#{tunnel_id}" and m.status in ["pending", "inflight"])
    |> Repo.all()
    |> Enum.filter(fn m -> to_string(m.meta["seq"]) == to_string(seq) end)
    |> Enum.each(&Outbox.mark_acked/1)

    pending = Map.delete(pending, {tunnel_id, seq})

    {:noreply,
     state
     |> Map.put(:pending_acks, pending)
     |> update_in([:stats, :acked], &(&1 + 1))}
  end

  def handle_cast({:track_send, tunnel_id, seq, sent_at, peer}, state) do
    pending = Map.put(state.pending_acks, {tunnel_id, seq}, {sent_at, peer})
    {:noreply, %{state | pending_acks: pending}}
  end

  defp drain_outbox(state) do
    Enum.reduce(Outbox.due(16), state, fn msg, acc ->
      case dispatch(msg) do
        :ok ->
          {:ok, _} = Outbox.mark_inflight(msg)
          update_in(acc, [:stats, :sent], &(&1 + 1))

        {:error, reason} ->
          {:ok, _} = Outbox.mark_retry(msg, reason)
          acc
      end
    end)
  end

  defp dispatch(%{channel: "tunnel:" <> tunnel_id} = msg) do
    case Repo.get_by(Peer, tunnel_id: tunnel_id) do
      nil ->
        {:error, :unknown_tunnel}

      %Peer{enabled: false} ->
        {:error, :tunnel_disabled}

      peer ->
        case Governor.allow?(:tunnel_data, peer.carrier_network, tunnel_id) do
          {:drop, reason} ->
            {:ok, _} = Outbox.mark_retry(msg, {:governor, reason})
            {:error, {:governor, reason}}

          :ok ->
            send_over_carrier(peer, msg)
        end
    end
  end

  defp dispatch(_msg), do: {:error, :unknown_channel}

  defp send_over_carrier(peer, payload) do
    carrier = network_atom(peer.carrier_network)
    adapter = Networks.adapter!(carrier)
    mtu = if function_exported?(adapter, :mtu, 1), do: adapter.mtu(%{}), else: 200

    {:ok, peer} = Tunnel.bump_seq(peer)
    frames = Tunnel.encode_fragments(peer, payload, mtu)
    sent_at = System.monotonic_time(:millisecond)

    result =
      Enum.reduce_while(frames, :ok, fn frame, :ok ->
        encoded = Frame.encode(frame)

        send_result =
          if function_exported?(adapter, :send_raw, 2) do
            adapter.send_raw(encoded, %{peer_ref: peer.peer_ref, tunnel_id: peer.tunnel_id})
          else
            {:error, :adapter_no_raw}
          end

        case send_result do
          :ok -> {:cont, :ok}
          other -> {:halt, other}
        end
      end)

    if result == :ok do
      GenServer.cast(
        self(),
        {:track_send, peer.tunnel_id, peer.next_seq - 1, sent_at, peer}
      )
    end

    result
  end

  defp record_ack_latency(tunnel_id, seq, pending) do
    case Map.get(pending, {tunnel_id, seq}) do
      {sent_at, %Peer{} = peer} ->
        latency_ms = System.monotonic_time(:millisecond) - sent_at

        _ =
          Sightings.record(%{
            network: peer.carrier_network,
            direction: "out",
            identity_ref: peer.peer_ref,
            tunnel_id: tunnel_id,
            hops: 0,
            latency_ms: latency_ms,
            meta: %{source: "tunnel_ack", seq: seq}
          })

        Phoenix.PubSub.broadcast(
          Isthmus.PubSub,
          "announce:sightings",
          {:sighting, %{tunnel_id: tunnel_id, latency_ms: latency_ms}}
        )

      _ ->
        :ok
    end
  end

  defp ingest_frame(%Frame{flags: flags} = frame, state) do
    cond do
      Bitwise.band(flags, Frame.flag_ack()) != 0 ->
        tunnel_hex = Base.encode16(frame.tunnel_id, case: :lower)
        GenServer.cast(self(), {:ack, tunnel_hex, frame.seq})
        state

      Bitwise.band(flags, Frame.flag_data()) != 0 ->
        reassemble(frame, state)

      true ->
        state
    end
  end

  defp reassemble(frame, state) do
    key = {frame.tunnel_id, frame.seq}
    parts = Map.get(state.reassembly, key, %{})
    parts = Map.put(parts, frame.frag_idx, frame.payload)

    if map_size(parts) == frame.frag_cnt do
      payload =
        0..(frame.frag_cnt - 1)
        |> Enum.map(&Map.fetch!(parts, &1))
        |> IO.iodata_to_binary()

      if Frame.hash16(payload) == frame.payload_hash16 do
        deliver_payload(frame.tunnel_id, payload)
        ack = Frame.encode(Frame.ack_frame(frame.tunnel_id, frame.seq))
        maybe_send_ack(frame.tunnel_id, ack)

        state
        |> update_in([:reassembly], &Map.delete(&1, key))
        |> update_in([:stats, :reassembled], &(&1 + 1))
      else
        Logger.warning("tunnel reassembly hash mismatch")
        update_in(state, [:reassembly], &Map.delete(&1, key))
      end
    else
      put_in(state, [:reassembly, key], parts)
    end
  end

  defp deliver_payload(tunnel_id_bin, payload) do
    tunnel_hex = Base.encode16(tunnel_id_bin, case: :lower)

    case Repo.get_by(Peer, tunnel_id: tunnel_hex) do
      %Peer{} = peer ->
        payload_net = network_atom(peer.payload_network)
        adapter = Networks.adapter!(payload_net)

        if function_exported?(adapter, :send_raw, 2) do
          adapter.send_raw(payload, %{direction: :from_tunnel, tunnel_id: tunnel_hex})
        else
          Logger.info(
            "tunnel delivered #{byte_size(payload)} bytes for #{tunnel_hex} (no inject)"
          )

          :ok
        end

      nil ->
        Logger.debug("inbound frame for unknown tunnel #{tunnel_hex}")
        :ok
    end
  end

  defp maybe_send_ack(tunnel_id_bin, ack_binary) do
    tunnel_hex = Base.encode16(tunnel_id_bin, case: :lower)

    with %Peer{} = peer <- Repo.get_by(Peer, tunnel_id: tunnel_hex),
         carrier <- network_atom(peer.carrier_network),
         adapter <- Networks.adapter!(carrier),
         true <- function_exported?(adapter, :send_raw, 2) do
      adapter.send_raw(ack_binary, %{peer_ref: peer.peer_ref, kind: :ack})
    else
      _ -> :ok
    end
  end

  defp network_atom(name) when is_binary(name) do
    case name do
      "reticulum" -> :reticulum
      "meshcore" -> :meshcore
      "nostr" -> :nostr
      other -> String.to_atom(other)
    end
  end

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_ms)
end
