defmodule Isthmus.Tunnel.Engine do
  @moduledoc """
  Drains the durable outbox, fragments payloads for the carrier MTU, and
  dispatches via network adapters. Reassembly buffer kept in-process.

  Inbound ISTH frames: ACK / DATA / CONTROL. DATA payloads are injected into
  the peer's `payload_network` via `send_raw/2`. CONTROL announces are applied
  locally with `from_tunnel: true` so they do not bounce.
  """
  use GenServer

  require Logger
  import Ecto.Query

  alias Isthmus.Announce.Sightings
  alias Isthmus.Announce.Governor
  alias Isthmus.Networks
  alias Isthmus.Tunnel
  alias Isthmus.Tunnel.{Bridge, Frame, Outbox, Peer}
  alias Isthmus.Tunnel.Outbox.Message
  alias Isthmus.Repo

  @tick_ms 5_000
  @ping_ms 30_000

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

  @doc """
  Per-tunnel reachability derived from the keepalive ping loop.

  Returns a map of `tunnel_id => %{status, rtt_ms, last_ack_at, last_ping_at,
  misses}` where `status` is `:reachable | :unreachable | :unknown`. Safe to call
  when the Engine isn't running (returns `%{}`).
  """
  def health do
    GenServer.call(__MODULE__, :health)
  catch
    :exit, _ -> %{}
  end

  @doc """
  Classify a raw carrier blob: ISTH frames go to the Engine; otherwise treat as
  island traffic for `payload_network` (auto-bridge).
  """
  def ingest_carrier_blob(payload_network, binary, opts \\ %{})
      when is_binary(payload_network) and is_binary(binary) do
    case Frame.decode(binary) do
      {:ok, _frame, _rest} ->
        handle_inbound_frame(binary)

      {:error, _} ->
        Bridge.forward_packet(payload_network, binary, opts)
    end
  end

  @impl true
  def init(_opts) do
    Sightings.purge_expired()

    state = %{
      reassembly: %{},
      pending_acks: %{},
      liveness: %{},
      stats: %{sent: 0, acked: 0, dropped: 0, reassembled: 0, control: 0}
    }

    schedule_tick()
    schedule_ping()
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    Sightings.purge_expired()
    state = drain_outbox(state)
    schedule_tick()
    {:noreply, state}
  end

  # Keepalive: ping every enabled peer so the UI can show reachability + RTT even
  # when no announces are flowing. Pings are sent directly over the carrier
  # (never through the outbox/governor) so they can't exhaust the announce budget
  # or spam governor_events.
  def handle_info(:ping, state) do
    state =
      if ping_enabled?() do
        try do
          ping_enabled_peers(state)
        rescue
          e ->
            Logger.debug("tunnel ping sweep failed: #{inspect(e)}")
            state
        catch
          :exit, _ -> state
        end
      else
        state
      end

    schedule_ping()
    {:noreply, state}
  end

  @impl true
  def handle_call(:health, _from, state) do
    {:reply, compute_health(state.liveness), state}
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
    state =
      case Map.get(pending, {tunnel_id, seq}) do
        {sent_at, %Peer{}, :ping} ->
          rtt_ms = System.monotonic_time(:millisecond) - sent_at
          now_ms = System.system_time(:millisecond)

          Phoenix.PubSub.broadcast(
            Isthmus.PubSub,
            "tunnel:events",
            {:tunnel_ping, %{tunnel_id: tunnel_id, rtt_ms: rtt_ms}}
          )

          %{state | liveness: mark_ack_liveness(state.liveness, tunnel_id, now_ms, rtt_ms)}

        {sent_at, %Peer{} = peer} ->
          record_ack_latency(peer, tunnel_id, seq, sent_at)
          state

        _ ->
          state
      end

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
        class = if control_msg?(msg), do: :tunnel_control, else: :tunnel_data

        case Governor.allow?(class, peer.carrier_network, tunnel_id) do
          # drain_outbox marks the retry; don't double-count attempts here.
          {:drop, reason} -> {:error, {:governor, reason}}
          :ok -> send_over_carrier(peer, msg)
        end
    end
  end

  defp dispatch(_msg), do: {:error, :unknown_channel}

  defp send_over_carrier(%Peer{} = peer, %{payload: payload} = msg) when is_binary(payload) do
    carrier = network_atom(peer.carrier_network)
    adapter = Networks.adapter!(carrier)
    mtu = if function_exported?(adapter, :mtu, 1), do: adapter.mtu(%{}), else: 200

    seq = peer.next_seq
    frames = encode_outbound(peer, seq, payload, mtu, msg)
    {:ok, peer} = Tunnel.bump_seq(peer)
    sent_at = System.monotonic_time(:millisecond)

    result =
      Enum.reduce_while(frames, :ok, fn frame, :ok ->
        encoded = Frame.encode(frame)

        send_result =
          if exports?(adapter, :send_raw, 2) do
            adapter.send_raw(encoded, %{
              peer_ref: peer.peer_ref,
              tunnel_id: peer.tunnel_id,
              kind: if(control_msg?(msg), do: :control, else: :data)
            })
          else
            {:error, :adapter_no_raw}
          end

        case send_result do
          :ok -> {:cont, :ok}
          {:ok, _} -> {:cont, :ok}
          other -> {:halt, other}
        end
      end)

    if result == :ok do
      GenServer.cast(self(), {:track_send, peer.tunnel_id, seq, sent_at, peer})

      Phoenix.PubSub.broadcast(
        Isthmus.PubSub,
        "tunnel:events",
        {:tunnel_sent, %{tunnel_id: peer.tunnel_id, seq: seq, bytes: byte_size(payload)}}
      )
    end

    result
  end

  defp send_over_carrier(_peer, _msg), do: {:error, :invalid_outbox_payload}

  defp encode_outbound(peer, seq, payload, mtu, msg) do
    tid = Frame.tunnel_id_from_string(peer.tunnel_id)

    if control_msg?(msg) do
      [Frame.control_frame(tid, seq, payload)]
    else
      Frame.fragment(tid, seq, payload, mtu)
    end
  end

  defp control_msg?(%{meta: meta}) when is_map(meta) do
    meta["kind"] in ["control", :control] or meta[:kind] in ["control", :control]
  end

  defp control_msg?(_), do: false

  defp record_ack_latency(%Peer{} = peer, tunnel_id, seq, sent_at) do
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
  end

  defp ingest_frame(%Frame{flags: flags} = frame, state) do
    cond do
      Bitwise.band(flags, Frame.flag_ack()) != 0 ->
        tunnel_hex = Base.encode16(frame.tunnel_id, case: :lower)
        GenServer.cast(self(), {:ack, tunnel_hex, frame.seq})
        state

      Bitwise.band(flags, Frame.flag_control()) != 0 ->
        handle_control(frame)
        update_in(state, [:stats, :control], &(&1 + 1))

      Bitwise.band(flags, Frame.flag_data()) != 0 ->
        reassemble(frame, state)

      true ->
        state
    end
  end

  defp handle_control(%Frame{} = frame) do
    tunnel_hex = Base.encode16(frame.tunnel_id, case: :lower)

    case Jason.decode(frame.payload) do
      {:ok, %{"op" => "announce", "network" => network, "ref" => ref} = body}
      when is_binary(network) and is_binary(ref) ->
        meta = Map.get(body, "meta", %{})

        result =
          Networks.announce(
            network,
            ref,
            Map.merge(Map.new(meta), %{from_tunnel: true, force: true})
          )

        Logger.debug("tunnel control announce #{network}/#{ref}: #{inspect(result)}")

        ack = Frame.encode(Frame.ack_frame(frame.tunnel_id, frame.seq))
        maybe_send_ack(frame.tunnel_id, ack)

        Phoenix.PubSub.broadcast(
          Isthmus.PubSub,
          "tunnel:events",
          {:tunnel_control, %{tunnel_id: tunnel_hex, op: "announce", network: network, ref: ref}}
        )

        :ok

      {:ok, %{"op" => "ping"}} ->
        # Reachability probe from the far side — ACK it so the sender can measure
        # RTT. No island side effects.
        ack = Frame.encode(Frame.ack_frame(frame.tunnel_id, frame.seq))
        maybe_send_ack(frame.tunnel_id, ack)
        :ok

      {:ok, other} ->
        Logger.debug("tunnel control ignored: #{inspect(other)}")
        :ok

      {:error, _} ->
        Logger.debug("tunnel control decode failed for #{tunnel_hex}")
        :ok
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

        opts = %{
          direction: :from_tunnel,
          from_tunnel: true,
          tunnel_id: tunnel_hex
        }

        # inject_raw/2 replays a foreign packet verbatim; send_raw/2 would
        # re-originate it from our own identity, which is wrong for a payload.
        result =
          cond do
            exports?(adapter, :inject_raw, 2) ->
              apply(adapter, :inject_raw, [payload, opts])

            exports?(adapter, :send_raw, 2) ->
              adapter.send_raw(payload, opts)

            true ->
              Logger.warning(
                "tunnel delivered #{byte_size(payload)} bytes for #{tunnel_hex} but #{payload_net} has no inject_raw/2 or send_raw/2"
              )

              {:error, :adapter_no_raw}
          end

        Phoenix.PubSub.broadcast(
          Isthmus.PubSub,
          "tunnel:events",
          {:tunnel_delivered,
           %{
             tunnel_id: tunnel_hex,
             payload_network: peer.payload_network,
             bytes: byte_size(payload),
             result: result
           }}
        )

        result

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
         true <- exports?(adapter, :send_raw, 2) do
      adapter.send_raw(ack_binary, %{peer_ref: peer.peer_ref, kind: :ack})
    else
      _ -> :ok
    end
  end

  defp network_atom(name) when is_binary(name) do
    case name do
      "reticulum" ->
        :reticulum

      "meshcore" ->
        :meshcore

      "nostr" ->
        :nostr

      "meshtastic" ->
        :meshtastic

      other ->
        try do
          String.to_existing_atom(other)
        rescue
          ArgumentError -> String.to_atom(other)
        end
    end
  end

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_ms)

  defp schedule_ping do
    if ping_enabled?(), do: Process.send_after(self(), :ping, ping_interval())
  end

  defp ping_enabled?, do: Application.get_env(:isthmus, :tunnel_ping_enabled, true)
  defp ping_interval, do: Application.get_env(:isthmus, :tunnel_ping_ms, @ping_ms)

  # A tunnel is considered stale (and thus unreachable) once it misses ~3 pings.
  defp ping_stale_ms, do: ping_interval() * 3

  defp ping_enabled_peers(state) do
    Peer
    |> where([p], p.enabled == true)
    |> Repo.all()
    |> Enum.reduce(state, &ping_peer/2)
  end

  defp ping_peer(%Peer{} = peer, state) do
    now_ms = System.system_time(:millisecond)
    state = %{state | liveness: touch_ping(state.liveness, peer.tunnel_id, now_ms)}

    try do
      carrier = network_atom(peer.carrier_network)
      adapter = Networks.adapter!(carrier)

      if exports?(adapter, :send_raw, 2) do
        seq = peer.next_seq
        tid = Frame.tunnel_id_from_string(peer.tunnel_id)
        payload = Jason.encode!(%{"v" => 1, "op" => "ping", "ts" => now_ms})
        encoded = Frame.encode(Frame.control_frame(tid, seq, payload))
        {:ok, _} = Tunnel.bump_seq(peer)
        sent_at = System.monotonic_time(:millisecond)

        send_result =
          adapter.send_raw(encoded, %{
            peer_ref: peer.peer_ref,
            tunnel_id: peer.tunnel_id,
            kind: :control
          })

        if ok_send?(send_result) do
          pending = Map.put(state.pending_acks, {peer.tunnel_id, seq}, {sent_at, peer, :ping})
          %{state | pending_acks: pending}
        else
          state
        end
      else
        state
      end
    rescue
      e ->
        Logger.debug("tunnel ping failed for #{peer.tunnel_id}: #{inspect(e)}")
        state
    end
  end

  # function_exported?/3 returns false for a module that hasn't been loaded yet,
  # which flakes by test/boot ordering. Force a load first.
  defp exports?(module, fun, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, fun, arity)
  end

  defp ok_send?(:ok), do: true
  defp ok_send?({:ok, _}), do: true
  defp ok_send?(_), do: false

  defp blank_liveness, do: %{last_ping_at: nil, last_ack_at: nil, rtt_ms: nil, misses: 0}

  # Record a ping attempt. If the previous ping was never acked, count it as a miss.
  defp touch_ping(liveness, tunnel_id, now_ms) do
    entry = Map.get(liveness, tunnel_id, blank_liveness())

    misses =
      if entry.last_ping_at != nil and
           (entry.last_ack_at == nil or entry.last_ack_at < entry.last_ping_at) do
        entry.misses + 1
      else
        entry.misses
      end

    Map.put(liveness, tunnel_id, %{entry | last_ping_at: now_ms, misses: misses})
  end

  defp mark_ack_liveness(liveness, tunnel_id, now_ms, rtt_ms) do
    entry = Map.get(liveness, tunnel_id, blank_liveness())
    Map.put(liveness, tunnel_id, %{entry | last_ack_at: now_ms, rtt_ms: rtt_ms, misses: 0})
  end

  defp compute_health(liveness) do
    now_ms = System.system_time(:millisecond)
    stale = ping_stale_ms()

    Map.new(liveness, fn {tunnel_id, e} ->
      status =
        cond do
          e.last_ack_at != nil and now_ms - e.last_ack_at <= stale -> :reachable
          e.last_ping_at != nil -> :unreachable
          true -> :unknown
        end

      {tunnel_id,
       %{
         status: status,
         rtt_ms: e.rtt_ms,
         last_ack_at: e.last_ack_at,
         last_ping_at: e.last_ping_at,
         misses: e.misses
       }}
    end)
  end
end
