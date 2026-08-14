defmodule Isthmus.Gateway.Translator do
  @moduledoc """
  Routes normalized messages across registration-group legs.

  Trust boundary: Isthmus decrypts/re-encrypts at the edge.

  Nostr path uses a **per-group proxy** nsec (minted on the registration/bridge):
  - outbound DMs to member/primary npubs are sent *from* that group's proxy
  - inbound gift-wraps addressed to a proxy (`#p` / decrypt) route to that group
  - optional NIP-17 `subject` (`isthmus/<slug>`) remains a secondary room hint
  - DMs to `ISTHMUS_NOSTR_NSEC` (service identity) are retained in
    `Networks.Nostr.ServiceInbox` for operators — they are **not** matched to groups
  - Outbound group DMs always send from that group's Nostr proxy (no service-key sender)
  """
  use GenServer

  require Logger

  alias Isthmus.Announce.Dedup
  alias Isthmus.Gateway
  alias Isthmus.Gateway.Deliver
  alias Isthmus.Gateway.Message
  alias Isthmus.Gateway.Resolve
  alias Isthmus.Networks.Nostr.ServiceInbox
  alias Isthmus.Nostr.Crypto
  alias Isthmus.Nostr.Event
  alias Isthmus.Registrations

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec ingest(Message.t() | map()) :: :ok
  def ingest(%Message{} = msg), do: GenServer.cast(__MODULE__, {:ingest, msg})

  def ingest(attrs) when is_map(attrs) do
    msg = struct(Message, Map.merge(%{meta: %{}}, Map.new(attrs)))
    ingest(msg)
  end

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(Isthmus.PubSub, "nostr:inbound")
    Phoenix.PubSub.subscribe(Isthmus.PubSub, "meshcore:inbound")
    Phoenix.PubSub.subscribe(Isthmus.PubSub, "meshtastic:inbound")
    Phoenix.PubSub.subscribe(Isthmus.PubSub, "reticulum:inbound")
    Phoenix.PubSub.subscribe(Isthmus.PubSub, "agent:inbound")
    {:ok, %{processed: 0, seen_ids: %{}}}
  end

  @impl true
  def handle_cast({:ingest, %Message{} = msg}, state) do
    case dedupe(state, msg) do
      {:duplicate, state} ->
        {:noreply, state}

      {:ok, state} ->
        _ = bridge(msg)
        {:noreply, update_in(state.processed, &(&1 + 1))}
    end
  end

  @impl true
  def handle_info({:event, _url, event}, state) when is_map(event) do
    _ = handle_nostr_event(event)
    {:noreply, state}
  end

  def handle_info({:meshcore_dm, attrs}, state) when is_map(attrs) do
    from_ref = attrs[:from_ref] || attrs["from_ref"]
    body = attrs[:body] || attrs["body"] || ""

    case Registrations.complete_bind("meshcore", from_ref, body) do
      {:ok, _} ->
        {:noreply, state}

      {:error, _} ->
        {:noreply, state}

      :error ->
        ingest(%Message{
          from_network: :meshcore,
          from_ref: from_ref,
          to_ref: attrs[:to_ref] || attrs["to_ref"],
          body: body,
          external_id: attrs[:external_id],
          meta: attrs[:meta] || %{}
        })

        {:noreply, state}
    end
  end

  def handle_info({:meshcore_channel, attrs}, state) when is_map(attrs) do
    channel_idx = attrs[:channel_idx] || attrs["channel_idx"]
    meta = Map.merge(attrs[:meta] || attrs["meta"] || %{}, %{"meshcore_channel" => channel_idx})

    ingest(%Message{
      from_network: :meshcore,
      from_ref: nil,
      to_ref: nil,
      body: attrs[:body] || attrs["body"] || "",
      external_id:
        attrs[:external_id] || "mc-ch-#{channel_idx}-#{System.unique_integer([:positive])}",
      meta: meta
    })

    {:noreply, state}
  end

  def handle_info({:meshtastic_dm, attrs}, state) when is_map(attrs) do
    ingest(%Message{
      from_network: :meshtastic,
      from_ref: attrs[:from_ref] || attrs["from_ref"],
      to_ref: attrs[:to_ref] || attrs["to_ref"],
      body: attrs[:body] || attrs["body"] || "",
      external_id: attrs[:external_id],
      meta: attrs[:meta] || %{}
    })

    {:noreply, state}
  end

  def handle_info({:meshtastic_channel, attrs}, state) when is_map(attrs) do
    channel_idx = attrs[:channel_idx] || attrs["channel_idx"]
    meta = Map.merge(attrs[:meta] || attrs["meta"] || %{}, %{"meshtastic_channel" => channel_idx})

    ingest(%Message{
      from_network: :meshtastic,
      from_ref: attrs[:from_ref] || attrs["from_ref"],
      to_ref: nil,
      body: attrs[:body] || attrs["body"] || "",
      external_id:
        attrs[:external_id] || "mt-ch-#{channel_idx}-#{System.unique_integer([:positive])}",
      meta: meta
    })

    {:noreply, state}
  end

  def handle_info({:lxmf, attrs}, state) when is_map(attrs) do
    from_ref = attrs["from"] || attrs[:from]
    body = attrs["body"] || attrs[:body] || ""

    case Registrations.complete_bind("reticulum", from_ref, body) do
      {:ok, _} ->
        {:noreply, state}

      {:error, _} ->
        {:noreply, state}

      :error ->
        ingest(%Message{
          from_network: :reticulum,
          from_ref: from_ref,
          to_ref: attrs["to"] || attrs[:to],
          body: body,
          external_id: attrs["id"],
          meta: %{}
        })

        {:noreply, state}
    end
  end

  def handle_info({:agent_message, attrs}, state) when is_map(attrs) do
    ingest(%Message{
      from_network: :agent,
      from_ref: attrs[:from_ref] || attrs["from_ref"],
      to_ref: nil,
      body: attrs[:body] || attrs["body"] || "",
      external_id: attrs[:external_id] || "acp-#{System.unique_integer([:positive])}",
      meta: attrs[:meta] || attrs["meta"] || %{}
    })

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp handle_nostr_event(%{"kind" => kind} = event) when kind in [4, 1059] do
    with {:ok, _} <- Event.verify(event) do
      inboxes = Registrations.list_nostr_inbox_keypairs()

      if inboxes == [] do
        Logger.debug("nostr DM ignored (no proxy or ISTHMUS_NOSTR_NSEC)")
        :ok
      else
        case decrypt_nostr_with_inboxes(event, kind, inboxes) do
          {:ok, body, author, meta, to_hex} ->
            if kind == 1059 and not is_binary(meta["subject"] || meta[:subject]) do
              Logger.debug("nostr NIP-17 DM missing subject — routing by recipient proxy")
            end

            ingest(%Message{
              from_network: :nostr,
              from_ref: author,
              to_ref: to_hex,
              body: body,
              external_id: event["id"],
              meta: Map.merge(%{"kind" => kind}, Deliver.stringify_meta(meta))
            })

          {:error, reason} ->
            Logger.debug("nostr DM decrypt failed: #{inspect(reason)}")
            :ok
        end
      end
    else
      {:error, reason} ->
        Logger.debug("nostr event rejected: #{inspect(reason)}")
        :ok
    end
  rescue
    e ->
      Logger.warning("nostr DM handler crashed: #{Exception.message(e)}")
      :ok
  end

  defp handle_nostr_event(_), do: :ok

  defp decrypt_nostr_with_inboxes(event, kind, inboxes) do
    p_hexes = p_tag_pubkeys(event)

    ordered =
      if p_hexes == [] do
        inboxes
      else
        matching = Enum.filter(inboxes, fn {pk, _} -> pk in p_hexes end)
        rest = Enum.reject(inboxes, fn {pk, _} -> pk in p_hexes end)
        if matching == [], do: inboxes, else: matching ++ rest
      end

    Enum.find_value(ordered, fn {pk, seckey} ->
      should_try? = kind == 1059 or tagged_p?(event, pk)

      if should_try? do
        case Crypto.decrypt_inbound(seckey, event) do
          {:ok, body, author, meta} -> {:ok, body, author, meta, pk}
          _ -> nil
        end
      end
    end) || {:error, :decrypt_failed}
  end

  defp p_tag_pubkeys(event) do
    (event["tags"] || [])
    |> Enum.flat_map(fn
      ["p", pk | _] when is_binary(pk) -> [String.downcase(pk)]
      _ -> []
    end)
    |> Enum.uniq()
  end

  defp tagged_p?(event, hex) do
    hex in p_tag_pubkeys(event)
  end

  defp bridge(%Message{body: body} = msg) when body in [nil, ""] do
    Gateway.log(Deliver.log_attrs(msg, "none", "dropped", "empty_body"))
  end

  defp bridge(%Message{from_network: :nostr} = msg) do
    if service_recipient?(msg) do
      ServiceInbox.record(msg)
      Gateway.log(Deliver.log_attrs(msg, "none", "retained", "service_inbox"))
    else
      bridge_to_group(msg)
    end
  end

  defp bridge(%Message{} = msg), do: bridge_to_group(msg)

  defp bridge_to_group(%Message{} = msg) do
    {group, msg} = Resolve.group(msg)

    case group do
      nil ->
        Gateway.log(Deliver.log_attrs(msg, "none", "dropped", "no_registration"))

      group ->
        targets = Registrations.other_legs(group, msg.from_network, msg.from_ref)

        Enum.each(targets, fn dest_leg ->
          Deliver.leg(group, msg, dest_leg)
        end)

        Deliver.channels(group, msg)
    end
  end

  defp service_recipient?(%Message{to_ref: to}) when is_binary(to) do
    case Crypto.service_pubkey_hex() do
      hex when is_binary(hex) -> String.downcase(to) == hex
      _ -> false
    end
  end

  defp service_recipient?(_), do: false

  @persistent_dedup_networks [:nostr, "nostr", :reticulum, "reticulum"]
  @forward_dedup_ttl 7 * 24 * 60 * 60

  defp dedupe(state, %Message{external_id: id}) when id in [nil, ""], do: {:ok, state}

  defp dedupe(%{seen_ids: seen} = state, %Message{external_id: id} = msg) when is_binary(id) do
    cond do
      Map.has_key?(seen, id) ->
        {:duplicate, state}

      msg.from_network in @persistent_dedup_networks and
          Dedup.seen?(forward_dedup_key(msg, id), @forward_dedup_ttl) ->
        {:duplicate, %{state | seen_ids: remember_seen(seen, id)}}

      true ->
        {:ok, %{state | seen_ids: remember_seen(seen, id)}}
    end
  end

  defp remember_seen(seen, id) do
    seen
    |> Map.put(id, System.system_time(:second))
    |> trim_seen(200)
  end

  defp forward_dedup_key(%Message{from_network: net}, id), do: "gateway_ingest|#{net}|#{id}"

  defp trim_seen(seen, max) when map_size(seen) <= max, do: seen

  defp trim_seen(seen, max) do
    seen
    |> Enum.sort_by(fn {_id, ts} -> ts end, :desc)
    |> Enum.take(max)
    |> Map.new()
  end
end
