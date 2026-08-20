defmodule Isthmus.Networks.MeshCore.Companion.Frames do
  @moduledoc false

  require Logger

  alias Isthmus.Announce.Inbound
  alias Isthmus.Announce.Sightings
  alias Isthmus.Networks.MeshCore.Companion.Channels
  alias Isthmus.Networks.MeshCore.Companion.Status
  alias Isthmus.Networks.MeshCore.Protocol

  @spec apply(binary(), map()) :: map()
  def apply(frame, state) do
    case Protocol.parse_frame(frame) do
      {:raw_data, payload} ->
        Isthmus.Tunnel.Engine.ingest_carrier_blob("meshcore", payload, %{source: "companion_raw"})
        state

      {:advert, pubkey_hex} when is_binary(pubkey_hex) ->
        record_advert(pubkey_hex, state.contacts)
        Process.send_after(self(), :sync_contacts_boot, 500)
        state

      {:path_updated, pubkey_hex} ->
        Logger.debug("MeshCore path updated for #{pubkey_hex}")
        Process.send_after(self(), :sync_contacts_boot, 200)
        state

      {:contacts_start, count} ->
        Logger.info("MeshCore contacts sync starting (#{count})")
        state

      {:contact, contact} ->
        _ = record_contact_sighting(contact)
        put_in(state, [:contacts, contact.public_key], contact)

      {:end_of_contacts, lastmod} ->
        Logger.info("MeshCore contacts sync done (#{map_size(state.contacts)} contacts)")
        %{state | contacts_lastmod: lastmod}

      {:msg_waiting, true} ->
        send(self(), :poll_messages)
        state

      {:contact_msg, msg} ->
        maybe_record_peer_snr(msg)

        Phoenix.PubSub.broadcast(
          Isthmus.PubSub,
          "meshcore:inbound",
          {:meshcore_dm,
           %{
             from_ref: msg.from_ref,
             body: sanitize_text(msg.body),
             meta: Map.take(msg, [:timestamp, :txt_type, :snr, :score])
           }}
        )

        send(self(), :poll_messages)
        state

      {:channel_info, channel} ->
        state = put_in(state, [:channels, channel.index], channel)
        Channels.maybe_complete(state, channel.index)

      {:error, :remote} ->
        case state.channel_sync_awaiting do
          nil ->
            state

          idx ->
            state = put_in(state, [:channels, idx], Channels.empty_channel(idx))
            Channels.advance(state)
        end

      {:channel_msg, msg} ->
        send(self(), :poll_messages)
        ingest_channel_msg(state, msg)

      {:device_info, rest} ->
        info = Protocol.parse_device_info(rest)

        state
        |> Map.put(:max_channels, Channels.parse_max_channels(rest, state.max_channels))
        |> Map.put(:firmware_version, blank(info[:version]))
        |> Map.put(:firmware_model, blank(info[:model]))
        |> Status.publish()

      {:self_info, %{public_key: pubkey} = info} when is_binary(pubkey) ->
        Status.publish(%{state | self_info: info})

      {:no_more_messages, _} ->
        send(self(), :schedule_msg_poll)
        state

      other ->
        Logger.debug("meshcore frame: #{inspect(other)}")
        state
    end
  end

  @doc "Record Public channel messages that arrived before channel slots were known."
  def flush_pending(state) when is_map(state) do
    pending = Enum.reverse(state[:pending_channel_msgs] || [])

    Enum.each(pending, fn attrs ->
      idx = attrs[:channel_idx]
      attrs = Map.put(attrs, :slot, attrs[:slot] || get_in(state, [:channels, idx]))
      _ = Isthmus.Messages.maybe_record_meshcore_channel(attrs)

      Phoenix.PubSub.broadcast(
        Isthmus.PubSub,
        "meshcore:inbound",
        {:meshcore_channel, attrs}
      )
    end)

    Map.put(state, :pending_channel_msgs, [])
  end

  defp ingest_channel_msg(state, msg) do
    body = sanitize_text(msg.body)

    attrs = %{
      channel_idx: msg.channel_idx,
      body: body,
      seen_at: unix_seen_at(msg[:timestamp]),
      slot: get_in(state, [:channels, msg.channel_idx]),
      meta:
        Map.merge(Map.take(msg, [:timestamp, :txt_type, :snr]), %{
          radio_id: get_in(state, [:self_info, :public_key]),
          source: "companion_sync"
        })
    }

    if channels_ready?(state) do
      _ = Isthmus.Messages.maybe_record_meshcore_channel(attrs)

      Phoenix.PubSub.broadcast(
        Isthmus.PubSub,
        "meshcore:inbound",
        {:meshcore_channel, attrs}
      )

      state
    else
      pending = [attrs | state[:pending_channel_msgs] || []]
      Map.put(state, :pending_channel_msgs, pending)
    end
  end

  defp channels_ready?(state) do
    is_nil(state[:channel_sync_awaiting]) and
      (state[:channel_sync_queue] || []) == [] and
      map_size(state[:channels] || %{}) > 0
  end

  defp unix_seen_at(ts) when is_integer(ts) and ts > 1_600_000_000 and ts < 2_200_000_000 do
    DateTime.from_unix!(ts) |> DateTime.truncate(:second)
  end

  defp unix_seen_at(_), do: nil

  defp record_advert(pubkey_hex, contacts) when is_binary(pubkey_hex) and is_map(contacts) do
    name =
      case Map.get(contacts, String.downcase(pubkey_hex)) do
        %{name: n} when is_binary(n) and n != "" -> n
        _ -> nil
      end

    extra =
      case Map.get(contacts, String.downcase(pubkey_hex)) do
        %{hops: n} when is_integer(n) and n >= 0 -> %{hops: n}
        _ -> %{}
      end

    Inbound.record_meshcore(pubkey_hex, name, "push_advert", extra)
  end

  defp record_contact_sighting(%{public_key: ref} = contact) when is_binary(ref) do
    extra =
      case contact[:hops] do
        n when is_integer(n) and n >= 0 -> %{hops: n}
        _ -> %{}
      end

    name = contact[:name]

    if (is_binary(name) and name != "") or extra != %{} do
      Inbound.record_meshcore(ref, name, "contact", extra)
    else
      :ok
    end
  end

  defp record_contact_sighting(_), do: :ok

  defp maybe_record_peer_snr(%{from_ref: from_ref} = msg) when is_binary(from_ref) do
    snr = Map.get(msg, :snr)

    if snr != nil do
      _ =
        Sightings.record(%{
          network: "meshcore",
          direction: "in",
          identity_ref: from_ref,
          snr: snr / 4.0,
          meta: %{source: "contact_msg", score: Map.get(msg, :score)}
        })
    end
  end

  defp maybe_record_peer_snr(_), do: :ok

  defp sanitize_text(text) when is_binary(text) do
    text |> String.trim_trailing(<<0>>) |> String.trim()
  end

  defp blank(""), do: nil
  defp blank(v) when is_binary(v), do: v
  defp blank(_), do: nil
end
