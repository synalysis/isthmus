defmodule Isthmus.Networks.Meshtastic.Companion.Inbound do
  @moduledoc false

  require Logger

  alias Isthmus.Announce.Inbound, as: Sightings
  alias Isthmus.Networks.Meshtastic.Companion.Admin
  alias Isthmus.Networks.Meshtastic.Companion.Status
  alias Isthmus.Networks.Meshtastic.Protocol

  @spec consume(map(), binary()) :: map()
  def consume(state, data) do
    {frames, buffer} = Protocol.decode_stream(state.buffer <> data)

    Enum.reduce(frames, %{state | buffer: buffer}, fn payload, acc ->
      handle_payload(acc, payload)
    end)
  end

  def handle_payload(state, payload) do
    case Protocol.parse_frame(payload) do
      {:packet, pkt} ->
        handle_packet(%{state | received: state.received + 1}, pkt)

      {:my_info, info} ->
        Status.publish_status(%{state | my_info: info, last_error: nil})

      {:node_info, info} ->
        record_node_sighting(info, "node_db", state)
        note_own_node_time(%{state | received: state.received + 1}, info)

      {:channel, channel} ->
        Status.put_channel(state, channel)

      {:config, {:lora, lora}} ->
        Status.persist_lora(%{state | lora: lora})

      {:config, {:device, device}} ->
        Status.persist_device(%{state | device: device})

      {:config, _} ->
        state

      {:config_complete, nonce} ->
        if state.config_nonce == nonce do
          state
          |> Status.persist_channels()
          |> Status.broadcast_channels()
          |> Status.persist_lora()
          |> Status.broadcast_lora()
          |> Admin.maybe_begin_time_sync()
        else
          state
        end

      :rebooted ->
        Logger.info("Meshtastic companion rebooted — re-requesting config")
        Admin.request_config(state)

      {:other, _} ->
        state
    end
  end

  def handle_packet(state, %{portnum: port} = pkt) when port == 6 do
    Admin.maybe_handle_admin(state, pkt)
  end

  def handle_packet(state, %{portnum: port} = pkt) when port == 3 do
    pos = Protocol.parse_position(pkt.payload)
    maybe_note_device_time(state, pkt.from, pos.time)
  end

  def handle_packet(state, %{portnum: port} = pkt) when port == 67 do
    maybe_note_device_time(state, pkt.from, Protocol.parse_telemetry_time(pkt.payload))
  end

  def handle_packet(state, %{portnum: port} = pkt) when port == 1 do
    my_num = get_in(state, [:my_info, :my_node_num])

    cond do
      is_integer(my_num) and pkt.from == my_num ->
        state

      pkt.to == Protocol.broadcast() ->
        publish_channel_msg(%{
          channel_idx: pkt.channel,
          body: sanitize_text(pkt.payload),
          from_ref: Protocol.node_id_hex(pkt.from),
          meta: %{
            from: pkt.from,
            id: pkt.id,
            radio_id: get_in(state, [:my_info, :node_id]),
            port: state.port
          }
        })

        state

      is_integer(my_num) and pkt.to == my_num ->
        publish_dm(%{
          from_ref: Protocol.node_id_hex(pkt.from),
          to_ref: Protocol.node_id_hex(pkt.to),
          body: sanitize_text(pkt.payload),
          meta: %{id: pkt.id, channel: pkt.channel}
        })

        state

      true ->
        state
    end
  end

  def handle_packet(state, %{portnum: port} = pkt) when port == 4 do
    user = Protocol.parse_user(pkt.payload)
    node_id = user.node_id || Protocol.node_id_hex(pkt.from)

    record_node_sighting(
      %{
        num: pkt.from,
        node_id: node_id,
        name: user.name,
        short_name: user.short_name,
        snr: pkt[:snr],
        hops: pkt[:hops]
      },
      "nodeinfo",
      state
    )

    state
  end

  def handle_packet(state, _), do: state

  def publish_channel_msg(attrs) do
    Phoenix.PubSub.broadcast(
      Isthmus.PubSub,
      "meshtastic:inbound",
      {:meshtastic_channel,
       %{
         channel_idx: attrs[:channel_idx] || attrs["channel_idx"],
         body: attrs[:body] || attrs["body"] || "",
         from_ref: attrs[:from_ref] || attrs["from_ref"],
         meta: attrs[:meta] || attrs["meta"] || %{}
       }}
    )
  end

  def publish_dm(attrs) do
    Phoenix.PubSub.broadcast(
      Isthmus.PubSub,
      "meshtastic:inbound",
      {:meshtastic_dm,
       %{
         from_ref: attrs[:from_ref] || attrs["from_ref"],
         to_ref: attrs[:to_ref] || attrs["to_ref"],
         body: attrs[:body] || attrs["body"] || "",
         external_id: attrs[:external_id] || attrs["external_id"],
         meta: attrs[:meta] || attrs["meta"] || %{}
       }}
    )
  end

  def record_node_sighting(info, source, state \\ %{}) do
    my_num = get_in(state, [:my_info, :my_node_num])
    num = info[:num] || info["num"]
    node_id = info[:node_id] || info["node_id"]

    node_id =
      cond do
        is_binary(node_id) and node_id != "" ->
          node_id |> String.trim_leading("!") |> String.downcase()

        is_integer(num) and num > 0 ->
          Protocol.node_id_hex(num)

        true ->
          nil
      end

    cond do
      is_nil(node_id) ->
        :ok

      is_integer(my_num) and is_integer(num) and num == my_num ->
        :ok

      true ->
        extra =
          %{}
          |> maybe_put_extra(:hops, info[:hops] || info["hops"])
          |> maybe_put_extra(:snr, info[:snr] || info["snr"])

        Sightings.record_meshtastic(node_id, info[:name] || info["name"], source, extra)
    end
  end

  def maybe_put_extra(extra, :hops, n) when is_integer(n) and n >= 0,
    do: Map.put(extra, :hops, n)

  def maybe_put_extra(extra, :snr, n) when is_number(n) and n != 0, do: Map.put(extra, :snr, n)
  def maybe_put_extra(extra, _key, _value), do: extra

  def sanitize_text(text) when is_binary(text) do
    if String.valid?(text) do
      String.trim(text)
    else
      ""
    end
  end

  def sanitize_text(_), do: ""

  def note_own_node_time(state, info) when is_map(info) do
    my_num = get_in(state, [:my_info, :my_node_num])

    unix =
      cond do
        Status.valid_unix?(info[:position_time]) -> info.position_time
        Status.valid_unix?(info[:last_heard]) -> info.last_heard
        true -> 0
      end

    if is_integer(my_num) and info[:num] == my_num do
      maybe_note_device_time(state, my_num, unix)
    else
      state
    end
  end

  def maybe_note_device_time(state, from, unix) do
    my_num = get_in(state, [:my_info, :my_node_num])

    if Status.valid_unix?(unix) and (is_nil(my_num) or from == my_num) do
      Status.put_device_time(state, unix)
    else
      state
    end
  end
end
