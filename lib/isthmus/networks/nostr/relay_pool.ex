defmodule Isthmus.Networks.Nostr.RelayPool do
  @moduledoc """
  Manages WebSocket connections to configured Nostr relays and scopes
  subscriptions to registered pubkeys (not a global firehose).

  Per-relay reconnect is handled inside `RelayConnection`. This pool tracks
  status, fans out publishes to write-enabled relays (by priority), and emits telemetry.
  """
  use GenServer

  require Logger

  alias Isthmus.Announce.Governor
  alias Isthmus.Networks.Nostr.RelayConnection
  alias Isthmus.Registrations
  alias Isthmus.Relays

  @seen_event_limit 2_000
  @gateway_kinds [4, 14, 1059]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def health, do: GenServer.call(__MODULE__, :health)
  def reload, do: GenServer.cast(__MODULE__, :reload)

  def publish_event(event) when is_map(event) do
    GenServer.call(__MODULE__, {:publish, event}, 15_000)
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)

    state = %{
      connections: %{},
      statuses: %{},
      meta: %{},
      last_events: 0,
      seen_event_ids: %{},
      status: :starting
    }

    send(self(), :boot)
    {:ok, state}
  end

  @impl true
  def handle_info(:boot, state) do
    {:noreply, reconnect_all(state)}
  end

  def handle_info({:nostr_event, url, event}, state) do
    # Relays fan the same EVENT to every connection, and REQ subscriptions echo
    # our own publishes. Dedup by event id here — do NOT use Governor, which
    # keys :gateway_message on author pubkey and would drop distinct DMs/tunnel
    # frames from the same key for 10s while filling the audit log.
    {state, unique?} = remember_inbound_event(state, event)

    if unique? do
      _ = Isthmus.Networks.Nostr.TunnelCarrier.handle_inbound_event(event)
      maybe_broadcast_gateway_event(url, event)
    end

    {:noreply, update_in(state.last_events, &(&1 + 1))}
  end

  def handle_info({:relay_status, url, status}, state) do
    meta =
      Map.get(state.meta, url, %{})
      |> Map.merge(%{
        status: status,
        updated_at: System.system_time(:second),
        last_error:
          if(status == :online,
            do: nil,
            else: Map.get(Map.get(state.meta, url, %{}), :last_error)
          )
      })
      |> then(fn m ->
        if status == :online do
          Map.update(m, :connects, 1, &(&1 + 1))
        else
          Map.update(m, :disconnects, 1, &(&1 + 1))
        end
      end)

    {:noreply,
     state
     |> put_in([:statuses, url], status)
     |> put_in([:meta, url], meta)}
  end

  def handle_info({:EXIT, pid, reason}, state) do
    case Enum.find(state.connections, fn {_url, p} -> p == pid end) do
      {url, _} ->
        err = format_exit(reason)
        Logger.debug("relay #{url} exited: #{err}")

        meta =
          Map.get(state.meta, url, %{})
          |> Map.merge(%{
            status: :down,
            last_error: err,
            updated_at: System.system_time(:second)
          })
          |> Map.update(:disconnects, 1, &(&1 + 1))

        # Permission / crash storms: back off ensure
        delay = if match?({:error, %WebSockex.BadResponseError{}}, reason), do: 5_000, else: 2_000
        Process.send_after(self(), {:ensure_relay, url}, delay)

        {:noreply,
         state
         |> update_in([:connections], &Map.delete(&1, url))
         |> put_in([:statuses, url], :down)
         |> put_in([:meta, url], meta)}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:ensure_relay, url}, state) do
    relays =
      try do
        Relays.list_relays() |> Enum.filter(& &1.enabled)
      rescue
        DBConnection.OwnershipError -> []
      end

    relay = Enum.find(relays, &(&1.url == url))

    state =
      cond do
        is_nil(relay) ->
          state

        Map.has_key?(state.connections, url) and Process.alive?(state.connections[url]) ->
          state

        true ->
          start_relay(state, relay, build_filters())
      end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:health, _from, state) do
    relays = Relays.list_relays()
    online = Enum.count(state.statuses, fn {_u, s} -> s == :online end)

    by_url =
      Map.new(relays, fn relay ->
        status =
          Map.get(state.statuses, relay.url, if(relay.enabled, do: :unknown, else: :disabled))

        meta = Map.get(state.meta, relay.url, %{})

        {relay.url,
         %{
           status: status,
           enabled: relay.enabled,
           read: relay.read,
           write: relay.write,
           priority: relay.priority,
           connects: Map.get(meta, :connects, 0),
           disconnects: Map.get(meta, :disconnects, 0),
           last_error: Map.get(meta, :last_error),
           updated_at: Map.get(meta, :updated_at)
         }}
      end)

    {:reply,
     %{
       status: state.status,
       connections: map_size(state.connections),
       online: online,
       relays_enabled: Enum.count(relays, & &1.enabled),
       events_seen: state.last_events,
       by_url: by_url
     }, state}
  end

  def handle_call({:publish, event}, _from, state) do
    # Tunnel frames (kind 21278) are high-frequency and already rate-limited by
    # the Tunnel.Engine governor (tunnel_data / tunnel_control). Do NOT route
    # them through :nostr_metadata — that class dedups on the service pubkey
    # for 24h, which silently kills MeshCore/RNS-over-Nostr after the first
    # publish.
    case publish_allowed?(event) do
      {:drop, reason} ->
        {:reply, {:error, {:governor, reason}}, state}

      :ok ->
        {:reply, do_publish(event, state), state}
    end
  end

  defp publish_allowed?(event) when is_map(event) do
    kind = event["kind"] || event[:kind]

    if kind == Isthmus.Networks.Nostr.TunnelCarrier.kind() do
      :ok
    else
      Governor.allow?(:nostr_metadata, :nostr, event["pubkey"] || "publish")
    end
  end

  defp do_publish(event, state) do
    write_urls =
      Relays.list_relays()
      |> Enum.filter(&(&1.enabled and &1.write))
      |> Enum.sort_by(& &1.priority)
      |> Enum.map(& &1.url)
      |> Enum.filter(&Map.has_key?(state.connections, &1))

    results =
      Enum.map(write_urls, fn url ->
        try do
          case RelayConnection.publish(url, event) do
            :ok -> {url, :ok}
            other -> {url, other}
          end
        rescue
          e -> {url, {:error, e}}
        catch
          :exit, reason -> {url, {:error, reason}}
        end
      end)

    ok_count = Enum.count(results, fn {_u, r} -> r == :ok end)

    :telemetry.execute(
      [:isthmus, :nostr, :publish],
      %{ok: ok_count, total: length(results)},
      %{}
    )

    cond do
      write_urls == [] -> {:error, :no_write_relays}
      ok_count > 0 -> {:ok, results}
      true -> {:error, {:publish_failed, results}}
    end
  end

  @impl true
  def handle_cast(:reload, state) do
    {:noreply, reconnect_all(state)}
  end

  defp reconnect_all(state) do
    for {_url, pid} <- state.connections, is_pid(pid) and Process.alive?(pid) do
      Process.exit(pid, :shutdown)
    end

    filters = build_filters()

    relays =
      try do
        Relays.list_relays()
      rescue
        e in DBConnection.OwnershipError ->
          Logger.debug("relay reload skipped (db ownership): #{Exception.message(e)}")
          []
      end

    relays
    |> Enum.filter(& &1.enabled)
    |> Enum.sort_by(& &1.priority)
    |> Enum.reduce(%{state | connections: %{}, statuses: %{}, status: :running}, fn relay, acc ->
      start_relay(acc, relay, filters)
    end)
  end

  defp start_relay(state, relay, filters) do
    opts = %{
      url: relay.url,
      parent: self(),
      read: relay.read,
      write: relay.write,
      priority: relay.priority,
      auth_secret: relay.auth_secret,
      filters: if(relay.read, do: filters, else: [])
    }

    case RelayConnection.start_link(opts) do
      {:ok, pid} ->
        Process.link(pid)

        meta =
          Map.get(state.meta, relay.url, %{})
          |> Map.put(:status, :connecting)
          |> Map.put(:updated_at, System.system_time(:second))

        state
        |> put_in([:connections, relay.url], pid)
        |> put_in([:statuses, relay.url], :connecting)
        |> put_in([:meta, relay.url], meta)

      {:error, {:already_started, pid}} ->
        state
        |> put_in([:connections, relay.url], pid)
        |> put_in([:statuses, relay.url], :online)

      {:error, reason} ->
        Logger.warning("failed to connect #{relay.url}: #{inspect(reason)}")

        state
        |> put_in([:statuses, relay.url], :error)
        |> put_in([:meta, relay.url], %{
          status: :error,
          last_error: inspect(reason),
          updated_at: System.system_time(:second)
        })
    end
  end

  defp format_exit({:error, %_{} = err}), do: Exception.message(err)
  defp format_exit(reason), do: inspect(reason)

  defp remember_inbound_event(state, event) when is_map(event) do
    id = event["id"] || event[:id]

    cond do
      not is_binary(id) or id == "" ->
        {state, true}

      Map.has_key?(state.seen_event_ids, id) ->
        {state, false}

      true ->
        seen =
          state.seen_event_ids
          |> Map.put(id, System.system_time(:second))
          |> trim_seen_events()

        {%{state | seen_event_ids: seen}, true}
    end
  end

  defp remember_inbound_event(state, _), do: {state, true}

  defp trim_seen_events(seen) when map_size(seen) <= @seen_event_limit, do: seen

  defp trim_seen_events(seen) do
    seen
    |> Enum.sort_by(fn {_id, ts} -> ts end, :desc)
    |> Enum.take(@seen_event_limit)
    |> Map.new()
  end

  defp maybe_broadcast_gateway_event(url, event) when is_map(event) do
    kind = event["kind"] || event[:kind]

    if kind in @gateway_kinds do
      Phoenix.PubSub.broadcast(Isthmus.PubSub, "nostr:inbound", {:event, url, event})
    end
  end

  defp build_filters do
    try do
      pubkeys =
        Registrations.list_all()
        |> Enum.filter(&(&1.status == "active"))
        |> Enum.flat_map(fn g ->
          Enum.filter(g.legs, &(&1.network == "nostr")) |> Enum.map(& &1.identity_ref)
        end)

      service = Isthmus.Nostr.Crypto.service_pubkey_hex()
      pubkeys = if service, do: [service | pubkeys], else: pubkeys
      pubkeys = pubkeys |> Enum.uniq() |> Enum.take(50)

      if pubkeys == [] do
        [Isthmus.Networks.Nostr.TunnelCarrier.filter_global()]
      else
        [
          %{"kinds" => [4, 14, 1059], "authors" => pubkeys, "limit" => 20},
          %{"kinds" => [4, 14, 1059], "#p" => pubkeys, "limit" => 20},
          Isthmus.Networks.Nostr.TunnelCarrier.filter_global()
        ] ++
          if(service,
            do: [Isthmus.Networks.Nostr.TunnelCarrier.filter_for_service(service)],
            else: []
          )
      end
    rescue
      DBConnection.OwnershipError -> []
    end
  end
end
