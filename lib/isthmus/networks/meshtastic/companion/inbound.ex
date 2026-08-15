defmodule Isthmus.Networks.Meshtastic.Companion.Inbound do
  @moduledoc false

  require Logger

  alias Isthmus.Announce.Inbound, as: Sightings
  alias Isthmus.Networks.Meshtastic.Companion.Admin
  alias Isthmus.Networks.Meshtastic.Companion.Link
  alias Isthmus.Networks.Meshtastic.Companion.Status
  alias Isthmus.Networks.Meshtastic.MessageStore
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
        state = Status.put_channel(state, channel)
        Status.broadcast_channels(state)

      {:config, {:lora, lora}} ->
        apply_lora(state, lora)

      {:config, {:device, device}} ->
        apply_device(state, device)

      {:config, {:both, device, lora}} ->
        state |> apply_device(device) |> apply_lora(lora)

      {:config, _} ->
        state

      {:config_complete, nonce} ->
        if is_reference(state[:config_timer]), do: Process.cancel_timer(state.config_timer)
        state = Map.put(state, :config_timer, nil)

        if state.config_nonce == nonce or is_nil(state.config_nonce) do
          Logger.info("Meshtastic config dump complete (nonce=#{nonce})")

          state
          |> Status.persist_channels()
          |> Status.broadcast_channels()
          |> Status.persist_lora()
          |> Status.broadcast_lora()
          |> Status.persist_device()
          |> Status.broadcast_device()
          |> finish_config_dump(history: true)
        else
          Logger.debug(
            "Meshtastic config_complete nonce #{inspect(nonce)} != #{inspect(state.config_nonce)}"
          )

          state
        end

      {:file_info, info} ->
        if is_binary(info[:name]) and info[:name] != "" do
          Logger.info("Meshtastic file #{info.name} (#{info.size} bytes)")
        end

        files = [info | state[:files] || []]
        %{state | files: files}

      {:xmodem, xmodem} ->
        handle_xmodem(state, xmodem)

      :rebooted ->
        Logger.info("Meshtastic companion rebooted — re-requesting config")
        reset_message_store(state) |> Admin.request_config()

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
        record_meshtastic_broadcast(state, pkt, pkt.payload)
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

  def handle_packet(state, %{portnum: port} = pkt) when port == 65 do
    sf = Protocol.parse_store_forward(pkt.payload)

    if sf.rr == Protocol.sf_router_text_broadcast() do
      record_meshtastic_broadcast(state, pkt, sf.text)
    end

    state
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

  def apply_lora(state, lora) when is_map(lora) do
    state = Status.persist_lora(%{state | lora: lora})
    Status.broadcast_lora(state)
  end

  def apply_device(state, device) when is_map(device) do
    state = Status.persist_device(%{state | device: device})
    Status.broadcast_device(state)
  end

  @doc "After want_config finishes or times out: fill missing LoRa, then time-sync."
  def finish_config_dump(state, opts \\ []) do
    state =
      state
      |> Admin.maybe_refresh_lora()
      |> then(fn state ->
        if is_map(state[:admin]), do: state, else: Admin.maybe_begin_time_sync(state)
      end)

    if Keyword.get(opts, :history, false) do
      schedule_message_store(state)
    else
      state
    end
  end

  defp record_meshtastic_broadcast(state, pkt, body) do
    attrs = %{
      channel_idx: pkt.channel,
      body: sanitize_text(body),
      from_ref: Protocol.node_id_hex(pkt.from),
      seen_at: unix_seen_at(pkt[:rx_time]),
      external_id: pkt.id,
      meta: %{
        from: pkt.from,
        id: pkt.id,
        rx_time: pkt[:rx_time],
        radio_id: get_in(state, [:my_info, :node_id]),
        port: state.port,
        source: "companion_sync"
      }
    }

    _ = Isthmus.Messages.maybe_record_meshtastic_channel(attrs)
    publish_channel_msg(attrs)
  end

  @store_pull_ms 2_000
  @store_retry_ms 1_000
  @xmodem_start_ms 20_000
  @xmodem_idle_ms 15_000

  def reset_message_store(state) do
    state
    |> cancel_timer(:store_pull_timer)
    |> cancel_timer(:xmodem_timer)
    |> Map.put(:history_requested, false)
    |> Map.put(:files, [])
    |> Map.put(:xmodem, nil)
    |> Map.put(:xmodem_timer, nil)
    |> Map.put(:store_pull_timer, nil)
  end

  defp schedule_message_store(state, delay \\ @store_pull_ms) do
    state = cancel_timer(state, :store_pull_timer)
    ref = Process.send_after(self(), :pull_message_store, delay)
    %{state | store_pull_timer: ref, history_requested: false}
  end

  @doc "Start (or resume) an XModem pull of `/Messages_*.msgs` after handshake."
  def request_message_store(state) do
    cond do
      is_map(state[:xmodem]) ->
        state

      state[:history_requested] ->
        state

      is_map(state[:admin]) ->
        schedule_message_store(state, @store_retry_ms)

      true ->
        start_message_store(state, store_filename_candidates(state))
    end
  end

  def retry_or_finish_xmodem(state) do
    xfer = state[:xmodem]
    rest = (xfer && xfer[:candidates]) || []

    cond do
      is_list(rest) and rest != [] ->
        Logger.warning("Meshtastic message-log download timed out; retrying #{hd(rest)}")
        start_message_store(%{state | xmodem: nil, history_requested: false}, rest)

      true ->
        Logger.warning("Meshtastic message-log download timed out")
        finish_xmodem(state)
    end
  end

  defp start_message_store(state, [filename | rest]) do
    write_xmodem(state, Protocol.xmodem_download_frame(filename))
    Logger.info("Meshtastic requesting on-device message log #{filename}")

    state
    |> cancel_timer(:xmodem_timer)
    |> Map.put(:history_requested, true)
    |> Map.put(:xmodem, %{filename: filename, candidates: rest, acc: <<>>, seq: 0})
    |> Map.put(:xmodem_timer, Process.send_after(self(), :xmodem_timeout, @xmodem_start_ms))
  end

  defp start_message_store(state, _) do
    Logger.info("Meshtastic has no on-device message-log filename left to try")
    finish_xmodem(%{state | history_requested: true})
  end

  defp store_filename_candidates(state) do
    from_manifest =
      (state[:files] || [])
      |> Enum.map(& &1[:name])
      |> Enum.filter(fn name ->
        is_binary(name) and String.contains?(name, "Messages_") and
          String.ends_with?(String.trim_trailing(name, <<0>>), ".msgs")
      end)
      |> Enum.map(&String.trim_trailing(&1, <<0>>))

    Enum.uniq(from_manifest ++ [MessageStore.filename(), "Messages_default.msgs"])
  end

  defp handle_xmodem(state, %{control: control} = xmodem) do
    cond do
      control == Protocol.xmodem_nak() ->
        rest = get_in(state, [:xmodem, :candidates]) || []
        Logger.info("Meshtastic has no on-device message log (#{xmodem_name(state)})")
        start_message_store(%{state | xmodem: nil, history_requested: false}, rest)

      control == Protocol.xmodem_can() ->
        Logger.warning("Meshtastic cancelled message-log transfer")
        finish_xmodem(state)

      control == Protocol.xmodem_ack() and is_map(state[:xmodem]) ->
        # Older PhoneAPI ACKs the filename before the first SOH.
        write_xmodem(state, Protocol.xmodem_frame(Protocol.xmodem_ack()))
        refresh_xmodem_timer(state, @xmodem_start_ms)

      control == Protocol.xmodem_eot() ->
        write_xmodem(state, Protocol.xmodem_frame(Protocol.xmodem_ack()))
        ingest_message_store(state)

      control == Protocol.xmodem_soh() ->
        xfer = state[:xmodem] || %{filename: MessageStore.filename(), acc: <<>>, seq: 0}
        acc = (xfer[:acc] || <<>>) <> (xmodem.buffer || <<>>)
        write_xmodem(state, Protocol.xmodem_frame(Protocol.xmodem_ack(), xmodem.seq))

        state
        |> Map.put(:xmodem, Map.merge(xfer, %{acc: acc, seq: xmodem.seq}))
        |> refresh_xmodem_timer(@xmodem_idle_ms)

      true ->
        state
    end
  end

  defp write_xmodem(state, frame), do: Link.write(state, frame)

  defp ingest_message_store(state) do
    blob = get_in(state, [:xmodem, :acc]) || <<>>
    rows = MessageStore.parse(blob)
    broadcasts = Enum.filter(rows, &(&1.type == :broadcast and &1.body != ""))

    Enum.each(broadcasts, fn row ->
      record_store_row(state, row)
    end)

    if rows == [] and blob != <<>> do
      preview = blob |> binary_part(0, min(byte_size(blob), 16)) |> Base.encode16(case: :lower)

      Logger.warning(
        "Meshtastic message log: 0 rows from #{byte_size(blob)} bytes (#{preview}...)"
      )
    else
      Logger.info(
        "Meshtastic message log: #{length(broadcasts)} channel broadcasts of #{length(rows)} stored (#{byte_size(blob)} bytes)"
      )
    end

    finish_xmodem(state)
  end

  defp record_store_row(state, row) do
    attrs = %{
      channel_idx: row.channel_idx,
      body: row.body,
      from_ref: Protocol.node_id_hex(row.sender),
      seen_at: unix_seen_at(row.timestamp),
      external_id: store_external_id(row),
      force: true,
      meta: %{
        from: row.sender,
        rx_time: row.timestamp,
        radio_id: get_in(state, [:my_info, :node_id]),
        port: state[:port],
        source: "message_store"
      }
    }

    _ = Isthmus.Messages.maybe_record_meshtastic_channel(attrs)
    publish_channel_msg(attrs)
  end

  defp store_external_id(row) do
    digest = row.body |> :erlang.phash2() |> Integer.to_string(16) |> String.downcase()
    "mt-store-#{row.sender}-#{row.timestamp}-#{digest}"
  end

  defp xmodem_name(state), do: get_in(state, [:xmodem, :filename]) || MessageStore.filename()

  defp finish_xmodem(state) do
    state
    |> cancel_timer(:xmodem_timer)
    |> Map.put(:xmodem, nil)
    |> Map.put(:xmodem_timer, nil)
  end

  defp refresh_xmodem_timer(state, ms) do
    state = cancel_timer(state, :xmodem_timer)
    %{state | xmodem_timer: Process.send_after(self(), :xmodem_timeout, ms)}
  end

  defp cancel_timer(state, key) do
    ref = state[key]
    if is_reference(ref), do: Process.cancel_timer(ref)
    Map.put(state, key, nil)
  end

  defp unix_seen_at(ts) when is_integer(ts) and ts > 1_600_000_000 and ts < 2_200_000_000 do
    DateTime.from_unix!(ts) |> DateTime.truncate(:second)
  end

  defp unix_seen_at(_), do: nil

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
          |> maybe_put_extra(
            :hops,
            info[:hops] || info["hops"] || info[:hops_away] || info["hops_away"]
          )
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
