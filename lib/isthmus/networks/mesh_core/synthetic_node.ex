defmodule Isthmus.Networks.MeshCore.SyntheticNode do
  @moduledoc """
  Isthmus-owned MeshCore identities that speak on the island via `BridgeLink`.

  Loads vaulted `meshcore/proxy` legs, injects adverts/DMs/PATH/ACK as those
  pubkeys, and decrypts inbound traffic addressed to them.
  """
  use GenServer

  require Logger

  alias Isthmus.Announce.Governor
  alias Isthmus.Announce.Sightings
  alias Isthmus.Networks.MeshCore.Advert
  alias Isthmus.Networks.MeshCore.BridgeLink
  alias Isthmus.Networks.MeshCore.Crypto
  alias Isthmus.Networks.MeshCore.Packet
  alias Isthmus.Networks.MeshCore.Path
  alias Isthmus.Networks.MeshCore.TxtMsg
  alias Isthmus.Registrations
  alias Isthmus.Tunnel

  @rx_topic "meshcore:bridge_rx"
  @status_table :isthmus_meshcore_synthetic_status
  @reload_ms 30_000
  @advert_tick_ms 60_000
  @max_hash_collisions 4
  # Path-insensitive de-dup window for inbound packets. In a cyclic tunnel mesh
  # the same DM/advert/PATH can reach us via several routes; without this we'd
  # deliver duplicate DMs and emit duplicate PATH+ACK. MeshCore retries bump the
  # `attempt` byte (new ciphertext → new hash), so genuine retransmits are not
  # suppressed — only exact duplicates are.
  @seen_ttl_ms 30_000
  @seen_max 4_096

  def child_spec(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    %{
      id: name,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def health(name \\ __MODULE__) do
    with table when table != :undefined <- :ets.whereis(@status_table),
         [{{:health, ^name}, health}] <- :ets.lookup(table, {:health, name}) do
      health
    else
      _ -> safe_call(name, :health, %{status: :unknown, identities: []}, 500)
    end
  end

  def identities(name \\ __MODULE__), do: health(name)[:identities] || []

  def has_identity?(name \\ __MODULE__, ref) when is_binary(ref) do
    hex = String.downcase(ref)
    Enum.any?(identities(name), &(&1.public_key == hex))
  end

  def reload(name \\ __MODULE__), do: GenServer.cast(name, :reload)

  def announce(name \\ __MODULE__, ref_or_leg, opts \\ %{})

  def announce(name, %{identity_ref: ref}, opts), do: announce(name, ref, opts)

  def announce(name, ref, opts) when is_binary(ref) do
    safe_call(
      name,
      {:announce, String.downcase(ref), Map.new(opts)},
      {:error, :not_started},
      5_000
    )
  end

  def send_text(name \\ __MODULE__, ref_or_leg, dest_pubkey, text)

  def send_text(name, %{identity_ref: ref}, dest, text), do: send_text(name, ref, dest, text)

  def send_text(name, ref, dest, text)
      when is_binary(ref) and is_binary(dest) and is_binary(text) do
    safe_call(
      name,
      {:send_text, String.downcase(ref), String.downcase(dest), text},
      {:error, :not_started},
      5_000
    )
  end

  defp safe_call(name, req, fallback, timeout) do
    GenServer.call(name, req, timeout)
  catch
    :exit, _ -> fallback
  end

  @impl true
  def init(opts) do
    ensure_ets(@status_table)
    Phoenix.PubSub.subscribe(Isthmus.PubSub, @rx_topic)

    cfg = Application.get_env(:isthmus, __MODULE__, [])

    autoload? =
      Keyword.get(opts, :autoload, Keyword.get(cfg, :autoload, true))

    state = %{
      name: Keyword.get(opts, :name, __MODULE__),
      inject: Keyword.get(opts, :inject, &BridgeLink.inject/1),
      bridge_health: Keyword.get(opts, :bridge_health, &BridgeLink.health/0),
      identities: %{},
      by_hash: %{},
      known_peers: %{},
      seen: %{},
      status: :disabled,
      autoload?: autoload?
    }

    if autoload? do
      Process.send_after(self(), :reload, 0)
      Process.send_after(self(), :advert_tick, @advert_tick_ms)
    end

    {:ok, publish(state)}
  end

  @impl true
  def handle_cast(:reload, state), do: {:noreply, publish(load_identities(state))}

  @impl true
  def handle_call(:health, _from, state), do: {:reply, health_map(state), state}

  def handle_call({:announce, ref, opts}, _from, state) do
    {reply, state} = do_announce(state, ref, opts)
    {:reply, reply, publish(state)}
  end

  def handle_call({:send_text, ref, dest, text}, _from, state) do
    {reply, state} = do_send_text(state, ref, dest, text)
    {:reply, reply, publish(state)}
  end

  @impl true
  def handle_info({:bridge_packet, packet}, state) when is_binary(packet) do
    {:noreply, publish(handle_packet(state, packet))}
  end

  def handle_info(:reload, state) do
    if state.autoload?, do: Process.send_after(self(), :reload, @reload_ms)
    {:noreply, publish(load_identities(state))}
  end

  def handle_info(:advert_tick, state) do
    if state.autoload?, do: Process.send_after(self(), :advert_tick, @advert_tick_ms)
    state = maybe_periodic_adverts(state)
    {:noreply, publish(state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp handle_packet(state, packet) do
    if bridge_online?(state) do
      case Packet.decode(packet) do
        {:ok, pkt} ->
          hash = Packet.packet_hash(pkt)
          state = prune_seen(state)

          if Map.has_key?(state.seen, hash) do
            state
          else
            dispatch(mark_seen(state, hash), pkt, packet)
          end

        _ ->
          state
      end
    else
      state
    end
  end

  defp mark_seen(state, hash) do
    now = System.monotonic_time(:millisecond)
    seen = Map.put(state.seen, hash, now + @seen_ttl_ms)

    seen =
      if map_size(seen) > @seen_max do
        seen |> Enum.reject(fn {_h, exp} -> exp <= now end) |> Map.new()
      else
        seen
      end

    %{state | seen: seen}
  end

  defp prune_seen(state) do
    now = System.monotonic_time(:millisecond)

    if Enum.any?(state.seen, fn {_h, exp} -> exp <= now end) do
      %{state | seen: state.seen |> Enum.reject(fn {_h, exp} -> exp <= now end) |> Map.new()}
    else
      state
    end
  end

  defp dispatch(state, %{payload_type: type} = pkt, _raw) do
    cond do
      type == Packet.type_advert() -> learn_advert(state, pkt)
      type == Packet.type_txt_msg() -> handle_txt(state, pkt)
      type == Packet.type_path() -> handle_path(state, pkt)
      true -> state
    end
  end

  defp learn_advert(state, %{payload: payload}) do
    case Advert.parse_payload(payload) do
      {:ok, %{public_key: pub}} ->
        hex = Base.encode16(pub, case: :lower)

        if Map.has_key?(state.identities, hex) do
          state
        else
          remember_peer(state, pub)
        end

      _ ->
        state
    end
  end

  defp handle_txt(state, pkt) do
    case pkt.payload do
      <<dest_hash::binary-1, _src_hash::binary-1, _::binary>> ->
        candidates = Map.get(state.by_hash, dest_hash, [])

        Enum.reduce_while(candidates, state, fn hex, acc ->
          case try_decrypt_txt(acc, hex, pkt) do
            {:ok, acc2} -> {:halt, acc2}
            :error -> {:cont, acc}
          end
        end)

      _ ->
        state
    end
  end

  defp try_decrypt_txt(state, hex, pkt) do
    id = Map.fetch!(state.identities, hex)
    peers = peer_pubs_for(state, id)

    case TxtMsg.decrypt(id.seed, id.pub, pkt, peers) do
      {:ok, msg} ->
        state =
          state
          |> remember_peer(msg.from_pub)
          |> touch_id(hex, :last_rx_at)
          |> ack_and_path(hex, pkt, msg)

        broadcast_dm(id, msg)
        {:ok, state}

      {:error, _} ->
        :error
    end
  end

  defp ack_and_path(state, hex, pkt, msg) do
    id = Map.fetch!(state.identities, hex)

    packet =
      if Packet.flood?(pkt) do
        Path.build_return(
          seed: id.seed,
          our_pub: id.pub,
          dest_pub: msg.from_pub,
          path: pkt.path,
          path_len: pkt.path_len,
          extra: msg.ack
        )
      else
        Path.build_ack_packet(msg.ack)
      end

    case inject(state, packet, hex) do
      {:ok, state} -> state
      {{:error, _}, state} -> state
    end
  end

  defp handle_path(state, pkt) do
    case pkt.payload do
      <<dest_hash::binary-1, src_hash::binary-1, _::binary>> ->
        candidates = Map.get(state.by_hash, dest_hash, [])

        Enum.reduce_while(candidates, state, fn hex, acc ->
          case try_path(acc, hex, src_hash, pkt) do
            {:ok, acc2} -> {:halt, acc2}
            :error -> {:cont, acc}
          end
        end)

      _ ->
        state
    end
  end

  defp try_path(state, hex, src_hash, pkt) do
    id = Map.fetch!(state.identities, hex)

    peer_pubs =
      peer_pubs_for(state, id)
      |> Enum.filter(&(Crypto.node_hash(&1) == src_hash))

    Enum.find_value(peer_pubs, :error, fn peer_pub ->
      case Path.decrypt(id.seed, id.pub, pkt, peer_pub) do
        {:ok, learned} ->
          state =
            state
            |> remember_peer(peer_pub)
            |> put_out_path(hex, peer_pub, learned.out_path, learned.out_path_len)
            |> touch_id(hex, :last_rx_at)

          {:ok, state}

        _ ->
          nil
      end
    end)
  end

  defp do_announce(state, ref, opts) do
    cond do
      not bridge_online?(state) ->
        {{:error, :bridge_offline}, state}

      not Map.has_key?(state.identities, ref) ->
        {{:error, :unknown_identity}, state}

      true ->
        id = Map.fetch!(state.identities, ref)
        force? = opts[:force] in [true, "true", "1", 1]

        allowed =
          if force?, do: :ok, else: Governor.allow?(:advert, :meshcore, ref)

        case allowed do
          :ok ->
            blob = Advert.build_flood(id.seed, id.pub, id.name)

            case inject(state, blob, ref) do
              {:ok, state} ->
                _ =
                  Sightings.record(%{
                    network: "meshcore",
                    direction: "out",
                    identity_ref: ref,
                    hops: nil,
                    meta: %{source: "synthetic_advert", flood: true}
                  })

                unless opts[:from_tunnel] in [true, "true", "1", 1] do
                  Tunnel.Bridge.forward_announce("meshcore", ref, %{
                    source: "synthetic_advert",
                    flood: true
                  })
                end

                {:ok, state}

              {{:error, _} = err, state} ->
                {err, state}
            end

          {:drop, reason} ->
            {{:error, {:governor, reason}}, state}
        end
    end
  end

  defp do_send_text(state, ref, dest_hex, text) do
    cond do
      not bridge_online?(state) ->
        {{:error, :bridge_offline}, state}

      not Map.has_key?(state.identities, ref) ->
        {{:error, :unknown_identity}, state}

      byte_size(dest_hex) != 64 ->
        {{:error, :invalid_dest}, state}

      true ->
        id = Map.fetch!(state.identities, ref)

        case Base.decode16(dest_hex, case: :mixed) do
          {:ok, dest_pub} when byte_size(dest_pub) == 32 ->
            state = remember_peer(state, dest_pub)
            {route, path_len, path} = route_for(id, dest_hex)

            case TxtMsg.build(
                   seed: id.seed,
                   our_pub: id.pub,
                   dest_pub: dest_pub,
                   text: text,
                   route: route,
                   path_len: path_len,
                   path: path
                 ) do
              {:ok, %{packet: packet}} ->
                case inject(state, packet, ref) do
                  {:ok, state} -> {:ok, state}
                  {{:error, _} = err, state} -> {err, state}
                end
            end

          _ ->
            {{:error, :invalid_dest}, state}
        end
    end
  end

  defp route_for(id, dest_hex) do
    case Map.get(id.paths, dest_hex) do
      %{path: path, path_len: path_len} -> {Packet.route_direct(), path_len, path}
      _ -> {Packet.route_flood(), 0, <<>>}
    end
  end

  defp inject(state, packet, hex) when is_binary(packet) do
    Tunnel.Bridge.mark_forwarded(packet)
    state = remember_own_packet(state, packet)

    case state.inject.(packet) do
      :ok ->
        {:ok, touch_id(state, hex, :last_tx_at)}

      {:error, reason} ->
        Logger.debug("synthetic inject failed: #{inspect(reason)}")
        {{:error, reason}, state}
    end
  end

  # Suppress reprocessing of our own injected packet when the local repeater
  # echoes it back on the bridge RX stream (with its own path hash appended).
  defp remember_own_packet(state, packet) do
    case Packet.decode(packet) do
      {:ok, pkt} -> mark_seen(state, Packet.packet_hash(pkt))
      _ -> state
    end
  end

  defp broadcast_dm(id, msg) do
    from_hex = Base.encode16(msg.from_pub, case: :lower)

    Phoenix.PubSub.broadcast(
      Isthmus.PubSub,
      "meshcore:inbound",
      {:meshcore_dm,
       %{
         from_ref: from_hex,
         to_ref: id.public_key,
         body: msg.text,
         meta: %{
           timestamp: msg.timestamp,
           synthetic: true,
           group_id: id.group_id
         }
       }}
    )
  end

  defp maybe_periodic_adverts(state) do
    if bridge_online?(state) do
      Enum.reduce(state.identities, state, fn {ref, _id}, acc ->
        case do_announce(acc, ref, %{force: false}) do
          {:ok, acc2} -> acc2
          {_, acc2} -> acc2
        end
      end)
    else
      state
    end
  end

  defp load_identities(state) do
    legs =
      try do
        Registrations.list_meshcore_proxy_legs()
      rescue
        e ->
          Logger.debug("synthetic identity load skipped: #{Exception.message(e)}")
          []
      catch
        :exit, reason ->
          Logger.debug("synthetic identity load exit: #{inspect(reason)}")
          []
      end

    identities =
      legs
      |> Enum.flat_map(fn leg ->
        case Registrations.meshcore_proxy_seed(leg) do
          {:ok, seed, pub} ->
            hex = String.downcase(leg.identity_ref)
            prev = Map.get(state.identities, hex, %{})

            [
              {hex,
               %{
                 public_key: hex,
                 seed: seed,
                 pub: pub,
                 leg_id: leg.id,
                 group_id: leg.registration_group_id,
                 name: proxy_name(leg),
                 paths: Map.get(prev, :paths, %{}),
                 last_rx_at: Map.get(prev, :last_rx_at),
                 last_tx_at: Map.get(prev, :last_tx_at)
               }}
            ]

          _ ->
            []
        end
      end)
      |> Map.new()

    by_hash =
      identities
      |> Enum.group_by(fn {_hex, id} -> Crypto.node_hash(id.pub) end, fn {hex, _} -> hex end)
      |> Map.new(fn {h, list} -> {h, Enum.take(list, @max_hash_collisions)} end)

    status = if bridge_online?(state) and map_size(identities) > 0, do: :online, else: :disabled

    %{state | identities: identities, by_hash: by_hash, status: status}
  end

  defp proxy_name(leg) do
    mat = leg.public_material || %{}
    mat["name"] || mat[:name] || "Isthmus"
  end

  defp peer_pubs_for(state, id) do
    from_known = Map.values(state.known_peers)
    from_paths = id.paths |> Map.keys() |> Enum.flat_map(&decode_pub/1)
    Enum.uniq(from_known ++ from_paths)
  end

  defp decode_pub(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, pub} when byte_size(pub) == 32 -> [pub]
      _ -> []
    end
  end

  defp remember_peer(state, pub) when byte_size(pub) == 32 do
    hex = Base.encode16(pub, case: :lower)
    %{state | known_peers: Map.put(state.known_peers, hex, pub)}
  end

  defp remember_peer(state, _), do: state

  defp put_out_path(state, hex, peer_pub, path, path_len) do
    peer_hex = Base.encode16(peer_pub, case: :lower)

    update_in(state, [:identities, hex], fn
      nil ->
        nil

      id ->
        %{id | paths: Map.put(id.paths, peer_hex, %{path: path, path_len: path_len})}
    end)
  end

  defp touch_id(state, hex, key) do
    update_in(state, [:identities, hex], fn
      nil -> nil
      id -> Map.put(id, key, DateTime.utc_now())
    end)
  end

  defp bridge_online?(state) do
    case state.bridge_health.() do
      %{status: :online} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp health_map(state) do
    identities =
      state.identities
      |> Enum.map(fn {hex, id} ->
        %{
          public_key: hex,
          group_id: id.group_id,
          leg_id: id.leg_id,
          name: id.name,
          path_peers: map_size(id.paths),
          last_rx_at: id.last_rx_at,
          last_tx_at: id.last_tx_at
        }
      end)
      |> Enum.sort_by(& &1.name)

    %{
      status: state.status,
      bridge_online: bridge_online?(state),
      identity_count: map_size(state.identities),
      known_peers: map_size(state.known_peers),
      identities: identities
    }
  end

  defp publish(state) do
    :ets.insert(@status_table, {{:health, state.name}, health_map(state)})
    state
  end

  defp ensure_ets(name) do
    case :ets.whereis(name) do
      :undefined -> :ets.new(name, [:named_table, :public, :set, read_concurrency: true])
      _ -> name
    end
  end
end
