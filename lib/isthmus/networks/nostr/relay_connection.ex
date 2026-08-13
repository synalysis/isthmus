defmodule Isthmus.Networks.Nostr.RelayConnection do
  @moduledoc """
  WebSocket connection to a single Nostr relay with reconnect backoff and optional NIP-42 AUTH.
  """
  use WebSockex

  require Logger

  @max_backoff_ms 60_000

  def start_link(%{url: url} = opts) do
    state = %{
      url: url,
      parent: opts[:parent],
      read: Map.get(opts, :read, true),
      write: Map.get(opts, :write, true),
      filters: opts[:filters] || [],
      auth_secret: opts[:auth_secret],
      priority: Map.get(opts, :priority, 100),
      attempt: 0,
      status: :connecting,
      last_error: nil
    }

    WebSockex.start_link(url, __MODULE__, state,
      name: via(url),
      handle_initial_conn_failure: true,
      async: true
    )
  end

  def via(url), do: {:via, Registry, {Isthmus.Networks.Nostr.Registry, url}}

  def publish(url, event) when is_map(event) do
    msg = Jason.encode!(["EVENT", event])
    WebSockex.send_frame(via(url), {:text, msg})
  end

  def subscribe(url, sub_id, filters) when is_list(filters) do
    msg = Jason.encode!(["REQ", sub_id | filters])
    WebSockex.send_frame(via(url), {:text, msg})
  end

  def health(url) do
    case Registry.lookup(Isthmus.Networks.Nostr.Registry, url) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_connected}
    end
  end

  @impl true
  def handle_connect(_conn, state) do
    Logger.info("Nostr relay connected #{state.url}")
    :telemetry.execute([:isthmus, :nostr, :relay, :connected], %{count: 1}, %{url: state.url})

    if state.parent, do: send(state.parent, {:relay_status, state.url, :online})

    # WebSockex 0.5 handle_connect only allows {:ok, state}. Send REQ via handle_info.
    if state.read and state.filters != [] do
      send(self(), :subscribe)
    end

    {:ok, %{state | attempt: 0, status: :online, last_error: nil}}
  end

  @impl true
  def handle_info(:subscribe, state) do
    if state.read and state.filters != [] do
      sub_id = "isthmus-" <> Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)
      msg = Jason.encode!(["REQ", sub_id | state.filters])
      {:reply, {:text, msg}, state}
    else
      {:ok, state}
    end
  end

  def handle_info(_msg, state), do: {:ok, state}

  @impl true
  def handle_frame({:text, msg}, state) do
    case Jason.decode(msg) do
      {:ok, ["EVENT", _sub, event]} when is_map(event) ->
        :telemetry.execute([:isthmus, :nostr, :relay, :event], %{count: 1}, %{url: state.url})
        if state.parent, do: send(state.parent, {:nostr_event, state.url, event})
        {:ok, state}

      {:ok, ["EOSE", _sub]} ->
        {:ok, state}

      {:ok, ["OK", _id, true, _]} ->
        :telemetry.execute([:isthmus, :nostr, :relay, :publish_ok], %{count: 1}, %{url: state.url})

        {:ok, state}

      {:ok, ["OK", _id, false, reason]} ->
        :telemetry.execute(
          [:isthmus, :nostr, :relay, :publish_fail],
          %{count: 1},
          %{url: state.url}
        )

        Logger.debug("nostr OK false #{state.url}: #{inspect(reason)}")
        {:ok, state}

      {:ok, ["AUTH", challenge]} when is_binary(challenge) ->
        case build_auth_event(state, challenge) do
          {:ok, event} ->
            {:reply, {:text, Jason.encode!(["AUTH", event])}, state}

          :skip ->
            Logger.debug("nostr AUTH requested but no auth_secret for #{state.url}")
            {:ok, state}
        end

      {:ok, ["NOTICE", notice]} ->
        Logger.debug("nostr notice #{state.url}: #{notice}")
        {:ok, state}

      _ ->
        {:ok, state}
    end
  end

  def handle_frame(_frame, state), do: {:ok, state}

  @impl true
  def handle_disconnect(%{reason: reason}, state) do
    attempt = state.attempt + 1
    backoff = min(@max_backoff_ms, trunc(:math.pow(2, min(attempt, 6)) * 500))

    # Avoid warning spam for routine reconnects; escalate only after a few failures.
    log_disconnect(state.url, reason, attempt, backoff)

    :telemetry.execute(
      [:isthmus, :nostr, :relay, :disconnected],
      %{count: 1, backoff_ms: backoff},
      %{url: state.url}
    )

    if state.parent do
      send(state.parent, {:relay_status, state.url, :reconnecting})
    end

    Process.sleep(backoff)

    {:reconnect,
     %{state | attempt: attempt, status: :reconnecting, last_error: format_reason(reason)}}
  end

  defp log_disconnect(url, reason, attempt, backoff) do
    msg =
      "Nostr relay #{url} disconnected (retry ##{attempt} in #{backoff}ms): #{format_reason(reason)}"

    if attempt <= 2 do
      Logger.debug(msg)
    else
      Logger.warning(msg)
    end
  end

  defp format_reason(%{__struct__: mod} = err), do: Exception.message(err) <> " (#{inspect(mod)})"
  defp format_reason(reason), do: inspect(reason)

  defp build_auth_event(%{auth_secret: secret, url: url}, challenge)
       when is_binary(secret) and secret != "" do
    with {:ok, "nsec", seckey} <- Isthmus.Nostr.Bech32.decode(String.trim(secret)),
         seckey <- Isthmus.Nostr.Crypto.normalize_seckey(seckey),
         seckey_hex <- Base.encode16(seckey, case: :lower) do
      event =
        22_242
        |> Nostr.Event.create(
          tags: [
            Nostr.Tag.create(:relay, url),
            Nostr.Tag.create(:challenge, challenge)
          ],
          content: ""
        )
        |> Isthmus.Nostr.Event.sign(seckey_hex)

      {:ok, Isthmus.Nostr.Event.to_wire_map(event)}
    else
      _ ->
        # Treat as raw 64-char hex seckey
        case Base.decode16(String.downcase(String.trim(secret)), case: :lower) do
          {:ok, seckey} when byte_size(seckey) == 32 ->
            seckey = Isthmus.Nostr.Crypto.normalize_seckey(seckey)
            seckey_hex = Base.encode16(seckey, case: :lower)

            event =
              22_242
              |> Nostr.Event.create(
                tags: [
                  Nostr.Tag.create(:relay, url),
                  Nostr.Tag.create(:challenge, challenge)
                ],
                content: ""
              )
              |> Isthmus.Nostr.Event.sign(seckey_hex)

            {:ok, Isthmus.Nostr.Event.to_wire_map(event)}

          _ ->
            :skip
        end
    end
  end

  defp build_auth_event(_, _), do: :skip
end
