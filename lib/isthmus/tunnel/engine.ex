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

  alias Isthmus.Announce.Governor
  alias Isthmus.Announce.Inbound
  alias Isthmus.Announce.Sightings
  alias Isthmus.Networks
  alias Isthmus.Networks.MeshCore.Advert
  alias Isthmus.Networks.MeshCore.Packet
  alias Isthmus.Networks.Reticulum
  alias Isthmus.Networks.Reticulum.Sidecar
  alias Isthmus.Tunnel
  alias Isthmus.Tunnel.{Bridge, Frame, Outbox, Peer}
  alias Isthmus.Tunnel.Outbox.Message
  alias Isthmus.Repo

  @tick_ms 5_000
  @ping_ms 30_000
  # Re-announce our isthmus.tunnel destination so peers can learn a return path
  # for addressed (point-to-point) delivery. Without this, one side may have a
  # path (works) while the other keeps hitting `no_path` (fails) — an asymmetry.
  @announce_ms 5 * 60_000
  # Soft-heal (request_path + tunnel announce) when a reticulum peer is
  # unreachable / has no path / is stuck on broadcast fallback. Not a sidecar restart.
  @heal_ms 60_000

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
  Per-tunnel reachability and path diagnostics from the keepalive loop.

  Returns a map of `tunnel_id => health` where health includes:

  * `status` — outbound RTT: `:reachable | :unreachable | :unknown`
  * `inbound_status` — whether we recently received traffic from them
  * `rtt_ms`, `last_ack_at`, `last_ping_at`, `misses`
  * `last_ping_mode` — `:addressed | :broadcast | :error | nil`
  * `last_inbound_at`, `last_inbound_kind`
  * `path` — RNS path snapshot when carrier is reticulum

  Safe to call when the Engine isn't running (returns `%{}`).
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
    Isthmus.Messages.purge_expired()

    state = %{
      reassembly: %{},
      pending_acks: %{},
      liveness: %{},
      last_announce_at: nil,
      stats: %{sent: 0, acked: 0, dropped: 0, reassembled: 0, control: 0}
    }

    schedule_tick()
    schedule_ping()
    {:ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    Sightings.purge_expired()
    Isthmus.Messages.purge_expired()
    _ = maybe_requeue_reachable(state)
    state = state |> prune_reassembly() |> drain_outbox()
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

    state = maybe_soft_heal(state)
    state = maybe_announce_tunnels(state)

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
      case authenticated_frame(binary) do
        {:ok, frame} -> ingest_frame(frame, state)
        :error -> state
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

          state = %{
            state
            | liveness: mark_ack_liveness(state.liveness, tunnel_id, now_ms, rtt_ms)
          }

          # Unattended recovery: any successful ping means durable DLQ rows can fly again.
          _ = Outbox.requeue_failed_for_tunnel(tunnel_id)

          state

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
    now_ms = System.system_time(:millisecond)

    Enum.reduce(Outbox.due(16), state, fn msg, acc ->
      cond do
        Outbox.ephemeral_expired?(msg) ->
          {:ok, _} = Outbox.expire(msg)
          update_in(acc, [:stats, :dropped], &(&1 + 1))

        durable_tunnel_unreachable?(msg, acc.liveness, now_ms) ->
          # Don't burn attempts while the peer is known down — wait and retry.
          {:ok, _} = Outbox.defer(msg, :tunnel_unreachable, 30)
          acc

        true ->
          case dispatch(msg) do
            :ok ->
              {:ok, _} = Outbox.mark_inflight(msg)
              update_in(acc, [:stats, :sent], &(&1 + 1))

            {:error, reason} ->
              case Outbox.mark_retry(msg, reason) do
                {:ok, %{status: "dropped"}} ->
                  update_in(acc, [:stats, :dropped], &(&1 + 1))

                {:ok, _} ->
                  acc

                _ ->
                  acc
              end
          end
      end
    end)
  end

  defp durable_tunnel_unreachable?(%{channel: "tunnel:" <> tunnel_id} = msg, liveness, now_ms) do
    Outbox.Class.durable?(msg.meta, msg.payload) and
      liveness_status(liveness, tunnel_id, now_ms) == :unreachable
  end

  defp durable_tunnel_unreachable?(_, _, _), do: false

  defp maybe_requeue_reachable(state) do
    now_ms = System.system_time(:millisecond)

    state.liveness
    |> Map.keys()
    |> Enum.each(fn tunnel_id ->
      if liveness_status(state.liveness, tunnel_id, now_ms) == :reachable do
        _ = Outbox.requeue_failed_for_tunnel(tunnel_id)
      end
    end)

    :ok
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
    case network_atom(peer.carrier_network) do
      nil ->
        {:error, :unknown_network}

      carrier ->
        adapter = Networks.adapter!(carrier)
        mtu = if function_exported?(adapter, :mtu, 1), do: adapter.mtu(%{}), else: 200

        seq = peer.next_seq
        frames = encode_outbound(peer, seq, payload, mtu, msg)
        {:ok, peer} = Tunnel.bump_seq(peer)
        sent_at = System.monotonic_time(:millisecond)

        result =
          Enum.reduce_while(frames, :ok, fn frame, :ok ->
            encoded = Frame.encode(frame, Tunnel.mac_key(peer))

            send_result =
              if exports?(adapter, :send_raw, 2) do
                try do
                  adapter.send_raw(encoded, %{
                    peer_ref: peer.peer_ref,
                    tunnel_id: peer.tunnel_id,
                    kind: if(control_msg?(msg), do: :control, else: :data)
                  })
                catch
                  :exit, reason ->
                    Logger.warning(
                      "tunnel carrier send exited (#{peer.carrier_network}): #{inspect(reason)}"
                    )

                    {:error, {:carrier_exit, reason}}
                end
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
        meta: %{source: "tunnel_ack", seq: seq, peer: peer.name, name: peer.name}
      })

    Phoenix.PubSub.broadcast(
      Isthmus.PubSub,
      "announce:sightings",
      {:sighting, %{tunnel_id: tunnel_id, latency_ms: latency_ms}}
    )
  end

  defp ingest_frame(%Frame{flags: flags} = frame, state) do
    tunnel_hex = Base.encode16(frame.tunnel_id, case: :lower)

    cond do
      Bitwise.band(flags, Frame.flag_ack()) != 0 ->
        state = mark_inbound(state, tunnel_hex, :ack)
        GenServer.cast(self(), {:ack, tunnel_hex, frame.seq})
        state

      Bitwise.band(flags, Frame.flag_control()) != 0 ->
        state = handle_control(frame, state)
        update_in(state, [:stats, :control], &(&1 + 1))

      Bitwise.band(flags, Frame.flag_data()) != 0 ->
        state = mark_inbound(state, tunnel_hex, :data)
        reassemble(frame, state)

      true ->
        state
    end
  end

  defp handle_control(%Frame{} = frame, state) do
    tunnel_hex = Base.encode16(frame.tunnel_id, case: :lower)

    case Jason.decode(frame.payload) do
      {:ok, %{"op" => "announce", "network" => network, "ref" => ref} = body}
      when is_binary(network) and is_binary(ref) ->
        state = mark_inbound(state, tunnel_hex, :control)
        meta = Map.get(body, "meta", %{})

        result =
          Networks.announce(
            network,
            ref,
            Map.merge(Map.new(meta), %{from_tunnel: true, force: true})
          )

        Logger.debug("tunnel control announce #{network}/#{ref}: #{inspect(result)}")

        maybe_send_ack(frame.tunnel_id, Frame.ack_frame(frame.tunnel_id, frame.seq))

        Phoenix.PubSub.broadcast(
          Isthmus.PubSub,
          "tunnel:events",
          {:tunnel_control, %{tunnel_id: tunnel_hex, op: "announce", network: network, ref: ref}}
        )

        state

      {:ok, %{"op" => "ping"}} ->
        # Far side can reach us — record inbound without flipping outbound reachable.
        state = mark_inbound(state, tunnel_hex, :ping)
        maybe_send_ack(frame.tunnel_id, Frame.ack_frame(frame.tunnel_id, frame.seq))
        state

      {:ok, other} ->
        Logger.debug("tunnel control ignored: #{inspect(other)}")
        state

      {:error, _} ->
        Logger.debug("tunnel control decode failed for #{tunnel_hex}")
        state
    end
  end

  defp reassemble(frame, state) do
    if frame.frag_cnt > Frame.max_frag_cnt() or frame.frag_idx >= frame.frag_cnt do
      state
    else
      key = {frame.tunnel_id, frame.seq}
      now = System.monotonic_time(:millisecond)
      entry = Map.get(state.reassembly, key, %{parts: %{}, at: now, frag_cnt: frame.frag_cnt})
      parts = Map.put(entry.parts, frame.frag_idx, frame.payload)
      entry = %{entry | parts: parts, frag_cnt: frame.frag_cnt}

      if map_size(parts) == frame.frag_cnt do
        payload =
          0..(frame.frag_cnt - 1)
          |> Enum.map(&Map.fetch!(parts, &1))
          |> IO.iodata_to_binary()

        deliver_payload(frame.tunnel_id, payload)
        maybe_send_ack(frame.tunnel_id, Frame.ack_frame(frame.tunnel_id, frame.seq))

        state
        |> update_in([:reassembly], &Map.delete(&1, key))
        |> update_in([:stats, :reassembled], &(&1 + 1))
      else
        put_in(state, [:reassembly, key], entry)
      end
    end
  end

  @reassembly_ttl_ms 30_000
  @max_reassembly 48

  defp prune_reassembly(%{reassembly: buf} = state) when map_size(buf) == 0, do: state

  defp prune_reassembly(%{reassembly: buf} = state) do
    now = System.monotonic_time(:millisecond)

    pruned =
      buf
      |> Enum.reject(fn
        {_k, %{at: at}} -> now - at > @reassembly_ttl_ms
        _ -> false
      end)
      |> Map.new()

    pruned =
      if map_size(pruned) > @max_reassembly do
        pruned
        |> Enum.sort_by(fn {_k, e} -> Map.get(e, :at, 0) end)
        |> Enum.take(-@max_reassembly)
        |> Map.new()
      else
        pruned
      end

    %{state | reassembly: pruned}
  end

  defp deliver_payload(tunnel_id_bin, payload) do
    tunnel_hex = Base.encode16(tunnel_id_bin, case: :lower)

    case Repo.get_by(Peer, tunnel_id: tunnel_hex) do
      %Peer{} = peer ->
        cond do
          peer.payload_network == "meshcore" and
              Bridge.blocked_channel_packet?("meshcore", payload, peer) ->
            finish_meshcore_skip(peer, tunnel_hex, payload, :channel_blocked)

          peer.payload_network == "meshcore" and Bridge.mark_forwarded(payload) == :duplicate ->
            finish_meshcore_skip(peer, tunnel_hex, payload, :duplicate)

          true ->
            # Record advert identity here (true ingress), before any radio echo
            # would mis-attribute the same packet as a local bridge hear.
            if peer.payload_network == "meshcore" do
              maybe_record_tunnel_meshcore_advert(peer, tunnel_hex, payload)
            end

            inject_payload_to_island(peer, tunnel_hex, payload)
        end

      nil ->
        Logger.debug("inbound frame for unknown tunnel #{tunnel_hex}")
        :ok
    end
  end

  defp finish_meshcore_skip(%Peer{} = peer, tunnel_hex, payload, reason) do
    result = {:ok, reason}

    Logger.debug(
      "tunnel→meshcore skip #{reason} inject via #{tunnel_hex} (#{peer.name}, #{byte_size(payload)}B)"
    )

    record_inbound_sighting(peer, tunnel_hex, result)

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
  end

  defp inject_payload_to_island(%Peer{} = peer, tunnel_hex, payload) do
    case network_atom(peer.payload_network) do
      nil ->
        {:error, :unknown_network}

      payload_net ->
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

        log_delivery(peer, tunnel_hex, byte_size(payload), result)
        record_inbound_sighting(peer, tunnel_hex, result)

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
    end
  end

  defp log_delivery(peer, tunnel_hex, bytes, result) do
    case result do
      :ok ->
        Logger.info(
          "tunnel→#{peer.payload_network} delivered #{bytes}B via #{tunnel_hex} (#{peer.name})"
        )

      {:ok, _} ->
        Logger.info(
          "tunnel→#{peer.payload_network} delivered #{bytes}B via #{tunnel_hex} (#{peer.name})"
        )

      {:error, reason} ->
        Logger.warning(
          "tunnel→#{peer.payload_network} inject FAILED (#{bytes}B) via #{tunnel_hex} (#{peer.name}): #{inspect(reason)}"
        )
    end
  end

  defp maybe_record_tunnel_meshcore_advert(%Peer{} = peer, tunnel_hex, payload)
       when is_binary(payload) do
    with {:ok, decoded} <- Packet.decode(payload),
         true <- decoded.payload_type == Packet.type_advert(),
         {:ok, %{public_key: pub, name: name}} <- Advert.parse_payload(decoded.payload) do
      hex = Base.encode16(pub, case: :lower)

      # Direction "out": we are sourcing this advert onto the local island.
      Inbound.record("meshcore", hex, name, "tunnel_advert", %{
        peer: peer.name,
        tunnel_id: tunnel_hex,
        direction: "out"
      })
    else
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  # Carrier-side "in" sighting for tunnel delivery diagnostics. Uses the carrier
  # network (not payload) so MeshCore-over-Nostr shows as nostr/in, matching
  # the outbound tunnel_ack rows (carrier/out) on the sending side.
  # Recorded whenever a DATA payload is reassembled — independent of whether
  # local island inject succeeded.
  defp record_inbound_sighting(peer, tunnel_hex, _result) do
    try do
      Sightings.record(%{
        network: peer.carrier_network,
        identity_ref: peer.peer_ref || tunnel_hex,
        direction: "in",
        tunnel_id: tunnel_hex,
        meta: %{"source" => "tunnel_data", "peer" => peer.name, "name" => peer.name}
      })
    rescue
      _ -> :ok
    end

    :ok
  end

  defp maybe_send_ack(tunnel_id_bin, %Frame{} = ack_frame) do
    tunnel_hex = Base.encode16(tunnel_id_bin, case: :lower)

    try do
      with %Peer{} = peer <- Repo.get_by(Peer, tunnel_id: tunnel_hex),
           carrier when not is_nil(carrier) <- network_atom(peer.carrier_network),
           adapter <- Networks.adapter!(carrier),
           true <- exports?(adapter, :send_raw, 2) do
        encoded = Frame.encode(ack_frame, Tunnel.mac_key(peer))
        adapter.send_raw(encoded, %{peer_ref: peer.peer_ref, kind: :ack})
      else
        _ -> :ok
      end
    catch
      :exit, _ -> :ok
    end
  end

  @networks ~w(reticulum meshcore nostr meshtastic agent)

  defp network_atom(name)
       when is_atom(name) and name in [:reticulum, :meshcore, :nostr, :meshtastic, :agent],
       do: name

  defp network_atom(name) when is_binary(name) and name in @networks do
    String.to_existing_atom(name)
  end

  defp network_atom(_), do: nil

  defp authenticated_frame(binary) when is_binary(binary) do
    with {:ok, frame, _rest} <- Frame.decode(binary),
         tunnel_hex <- Base.encode16(frame.tunnel_id, case: :lower),
         %Peer{} = peer <- Repo.get_by(Peer, tunnel_id: tunnel_hex),
         true <- Frame.valid_mac?(frame, Tunnel.mac_key(peer)) do
      {:ok, frame}
    else
      _ -> :error
    end
  end

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_ms)

  defp schedule_ping do
    if ping_enabled?(), do: Process.send_after(self(), :ping, ping_interval())
  end

  defp ping_enabled?, do: Application.get_env(:isthmus, :tunnel_ping_enabled, true)
  defp ping_interval, do: Application.get_env(:isthmus, :tunnel_ping_ms, @ping_ms)
  defp heal_interval, do: Application.get_env(:isthmus, :tunnel_heal_ms, @heal_ms)

  # When a reticulum peer looks one-way (no path / broadcast / unreachable),
  # request a path to them and re-announce our tunnel dest. Throttled per peer.
  defp maybe_soft_heal(state) do
    now_ms = System.system_time(:millisecond)

    peers =
      Peer
      |> where([p], p.enabled == true and p.carrier_network == ^"reticulum")
      |> Repo.all()

    {liveness, healed_any?} =
      Enum.reduce(peers, {state.liveness, false}, fn peer, {liv, any?} ->
        entry = Map.get(liv, peer.tunnel_id, blank_liveness())

        if needs_soft_heal?(entry, peer.tunnel_id, liv, now_ms) and heal_due?(entry, now_ms) do
          Logger.info(
            "tunnel soft-heal #{String.slice(peer.tunnel_id, 0, 12)}… " <>
              "(request_path + announce; mode=#{inspect(entry.last_ping_mode)} path=#{inspect(entry.path)})"
          )

          _ = safe_request_path(peer.peer_ref)
          entry = %{entry | last_heal_at: now_ms}
          {Map.put(liv, peer.tunnel_id, entry), true}
        else
          {liv, any?}
        end
      end)

    state = %{state | liveness: liveness}

    if healed_any? do
      _ = safe_tunnel_announce()
      Map.put(state, :last_announce_at, System.monotonic_time(:millisecond))
    else
      state
    end
  rescue
    e ->
      Logger.debug("tunnel soft-heal failed: #{inspect(e)}")
      state
  catch
    :exit, _ -> state
  end

  defp needs_soft_heal?(entry, tunnel_id, liveness, now_ms) do
    # Wait until we've actually pinged once so we don't heal on a cold start.
    if is_nil(entry.last_ping_at) do
      false
    else
      status = liveness_status(liveness, tunnel_id, now_ms)
      path_ok? = is_map(entry.path) and Map.get(entry.path, :path_known) == true
      broadcast? = entry.last_ping_mode == :broadcast
      send_error? = entry.last_ping_mode == :error

      cond do
        status == :reachable and path_ok? and not broadcast? and not send_error? ->
          false

        true ->
          true
      end
    end
  end

  defp heal_due?(%{last_heal_at: nil}, _now_ms), do: true

  defp heal_due?(%{last_heal_at: at}, now_ms) when is_integer(at),
    do: now_ms - at >= heal_interval()

  defp heal_due?(_, _), do: true

  defp safe_request_path(ref) when is_binary(ref) and ref != "" do
    Reticulum.request_path(ref)
  rescue
    e ->
      Logger.debug("tunnel request_path failed: #{inspect(e)}")
      :error
  catch
    :exit, _ -> :error
  end

  defp safe_request_path(_), do: :ok

  # Periodically re-announce our tunnel destination so remote peers can learn a
  # path back to us and use addressed delivery in BOTH directions.
  defp maybe_announce_tunnels(state) do
    now = System.monotonic_time(:millisecond)

    if announce_due?(state[:last_announce_at], now) and reticulum_tunnel_active?() do
      _ = safe_tunnel_announce()
      Map.put(state, :last_announce_at, now)
    else
      state
    end
  end

  defp announce_due?(nil, _now), do: true
  defp announce_due?(last, now), do: now - last >= @announce_ms

  defp reticulum_tunnel_active? do
    Reticulum.addressed_enabled?() and
      Repo.exists?(
        from(p in Peer, where: p.enabled == true and p.carrier_network == ^"reticulum")
      )
  rescue
    _ -> false
  end

  defp safe_tunnel_announce do
    if exports?(Sidecar, :tunnel_announce, 0) do
      Sidecar.tunnel_announce()
    else
      :ok
    end
  rescue
    e ->
      Logger.debug("tunnel_announce failed: #{inspect(e)}")
      :error
  catch
    :exit, _ -> :error
  end

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
    path = path_snapshot(peer)
    state = %{state | liveness: touch_ping(state.liveness, peer.tunnel_id, now_ms, path)}

    try do
      case network_atom(peer.carrier_network) do
        nil ->
          state

        carrier ->
          adapter = Networks.adapter!(carrier)

          if exports?(adapter, :send_raw, 2) do
            seq = peer.next_seq
            tid = Frame.tunnel_id_from_string(peer.tunnel_id)
            payload = Jason.encode!(%{"v" => 1, "op" => "ping", "ts" => now_ms})
            encoded = Frame.encode(Frame.control_frame(tid, seq, payload), Tunnel.mac_key(peer))
            {:ok, _} = Tunnel.bump_seq(peer)
            sent_at = System.monotonic_time(:millisecond)

            send_result =
              adapter.send_raw(encoded, %{
                peer_ref: peer.peer_ref,
                tunnel_id: peer.tunnel_id,
                kind: :control
              })

            {mode, err} = classify_send(send_result)

            state = %{
              state
              | liveness: record_ping_send(state.liveness, peer.tunnel_id, now_ms, mode, err)
            }

            if ok_send?(send_result) do
              pending = Map.put(state.pending_acks, {peer.tunnel_id, seq}, {sent_at, peer, :ping})
              %{state | pending_acks: pending}
            else
              state
            end
          else
            state
          end
      end
    rescue
      e ->
        Logger.debug("tunnel ping failed for #{peer.tunnel_id}: #{inspect(e)}")

        %{
          state
          | liveness:
              record_ping_send(
                state.liveness,
                peer.tunnel_id,
                now_ms,
                :error,
                Exception.message(e)
              )
        }
    catch
      :exit, reason ->
        Logger.debug("tunnel ping exited for #{peer.tunnel_id}: #{inspect(reason)}")

        %{
          state
          | liveness:
              record_ping_send(state.liveness, peer.tunnel_id, now_ms, :error, inspect(reason))
        }
    end
  end

  defp path_snapshot(%Peer{carrier_network: "reticulum", peer_ref: ref})
       when is_binary(ref) and ref != "" do
    case Reticulum.path_status(ref) do
      {:ok, status} when is_map(status) ->
        %{
          identity_known: status[:identity_known] == true or status["identity_known"] == true,
          path_known: status[:path_known] == true or status["path_known"] == true,
          destination_hash: status[:destination_hash] || status["destination_hash"] || ref,
          hops: status[:hops],
          next_hop: status[:next_hop],
          interface: status[:interface],
          nodes: status[:nodes] || []
        }

      _ ->
        %{
          identity_known: false,
          path_known: false,
          destination_hash: ref,
          hops: nil,
          next_hop: nil,
          interface: nil,
          nodes: []
        }
    end
  rescue
    _ ->
      %{
        identity_known: false,
        path_known: false,
        destination_hash: ref,
        hops: nil,
        next_hop: nil,
        interface: nil,
        nodes: []
      }
  catch
    :exit, _ ->
      %{
        identity_known: false,
        path_known: false,
        destination_hash: ref,
        hops: nil,
        next_hop: nil,
        interface: nil,
        nodes: []
      }
  end

  defp path_snapshot(_), do: nil

  defp classify_send(:ok), do: {:addressed, nil}
  defp classify_send({:ok, :addressed}), do: {:addressed, nil}
  defp classify_send({:ok, :broadcast}), do: {:broadcast, nil}
  defp classify_send({:ok, _}), do: {:addressed, nil}
  defp classify_send({:error, reason}), do: {:error, truncate_err(reason)}
  defp classify_send(other), do: {:error, truncate_err(other)}

  defp truncate_err(err) when is_binary(err), do: String.slice(err, 0, 120)
  defp truncate_err(err), do: err |> inspect() |> String.slice(0, 120)

  # function_exported?/3 returns false for a module that hasn't been loaded yet,
  # which flakes by test/boot ordering. Force a load first.
  defp exports?(module, fun, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, fun, arity)
  end

  defp ok_send?(:ok), do: true
  defp ok_send?({:ok, _}), do: true
  defp ok_send?(_), do: false

  defp blank_liveness do
    %{
      last_ping_at: nil,
      last_ack_at: nil,
      rtt_ms: nil,
      misses: 0,
      last_ping_mode: nil,
      last_ping_error: nil,
      last_inbound_at: nil,
      last_inbound_kind: nil,
      path: nil,
      last_heal_at: nil
    }
  end

  defp mark_inbound(state, tunnel_id, kind) do
    now_ms = System.system_time(:millisecond)
    entry = Map.get(state.liveness, tunnel_id, blank_liveness())

    liveness =
      Map.put(state.liveness, tunnel_id, %{
        entry
        | last_inbound_at: now_ms,
          last_inbound_kind: kind
      })

    %{state | liveness: liveness}
  end

  # Record a ping attempt. If the previous ping was never acked, count it as a miss.
  defp touch_ping(liveness, tunnel_id, now_ms, path) do
    entry = Map.get(liveness, tunnel_id, blank_liveness())

    misses =
      if entry.last_ping_at != nil and
           (entry.last_ack_at == nil or entry.last_ack_at < entry.last_ping_at) do
        entry.misses + 1
      else
        entry.misses
      end

    Map.put(liveness, tunnel_id, %{
      entry
      | last_ping_at: now_ms,
        misses: misses,
        path: path || entry.path
    })
  end

  defp record_ping_send(liveness, tunnel_id, now_ms, mode, error) do
    entry = Map.get(liveness, tunnel_id, blank_liveness())

    Map.put(liveness, tunnel_id, %{
      entry
      | last_ping_at: now_ms,
        last_ping_mode: mode,
        last_ping_error: error
    })
  end

  defp mark_ack_liveness(liveness, tunnel_id, now_ms, rtt_ms) do
    entry = Map.get(liveness, tunnel_id, blank_liveness())
    Map.put(liveness, tunnel_id, %{entry | last_ack_at: now_ms, rtt_ms: rtt_ms, misses: 0})
  end

  defp liveness_status(liveness, tunnel_id, now_ms) do
    case Map.get(liveness, tunnel_id) do
      nil ->
        :unknown

      e ->
        stale = ping_stale_ms()

        cond do
          e.last_ack_at != nil and now_ms - e.last_ack_at <= stale -> :reachable
          e.last_ping_at != nil -> :unreachable
          true -> :unknown
        end
    end
  end

  defp inbound_status(entry, now_ms) when is_map(entry) do
    stale = ping_stale_ms()

    cond do
      is_integer(entry.last_inbound_at) and now_ms - entry.last_inbound_at <= stale -> :fresh
      is_integer(entry.last_inbound_at) -> :stale
      true -> :none
    end
  end

  defp compute_health(liveness) do
    now_ms = System.system_time(:millisecond)

    Map.new(liveness, fn {tunnel_id, e} ->
      status = liveness_status(liveness, tunnel_id, now_ms)
      inbound = inbound_status(e, now_ms)

      {tunnel_id,
       %{
         status: status,
         inbound_status: inbound,
         inbound_only?: status != :reachable and inbound == :fresh,
         rtt_ms: e.rtt_ms,
         last_ack_at: e.last_ack_at,
         last_ping_at: e.last_ping_at,
         misses: e.misses,
         last_ping_mode: e.last_ping_mode,
         last_ping_error: e.last_ping_error,
         last_inbound_at: e.last_inbound_at,
         last_inbound_kind: e.last_inbound_kind,
         path: e.path
       }}
    end)
  end
end
