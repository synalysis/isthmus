defmodule Isthmus.Networks.Meshtastic.Protocol do
  @moduledoc """
  Meshtastic serial API framing and the protobuf subset Isthmus needs.

  Frame: `0x94 0xC3` + big-endian uint16 length + `ToRadio` / `FromRadio` protobuf.

  Field numbers follow meshtastic/protobufs (`mesh.proto`, `channel.proto`,
  `admin.proto`, `portnums.proto`).
  """

  alias Isthmus.Networks.Meshtastic.Protobuf

  @start1 0x94
  @start2 0xC3
  @max_frame 1024

  @port_text 1
  @port_position 3
  @port_admin 6
  @port_nodeinfo 4
  @port_telemetry 67

  @broadcast 0xFFFFFFFF

  @role_disabled 0
  @role_primary 1
  @role_secondary 2

  # AdminMessage.ConfigType — DEVICE_CONFIG is 0 (proto3 default). We still
  # encode the field so the get is not dropped.
  @config_device 0
  @config_position 1
  @config_lora 5

  def port_text, do: @port_text
  def port_position, do: @port_position
  def port_admin, do: @port_admin
  def port_nodeinfo, do: @port_nodeinfo
  def port_telemetry, do: @port_telemetry
  def broadcast, do: @broadcast
  def role_disabled, do: @role_disabled
  def role_primary, do: @role_primary
  def role_secondary, do: @role_secondary

  def encode_frame(payload) when is_binary(payload) do
    <<@start1, @start2, byte_size(payload)::big-16, payload::binary>>
  end

  def decode_stream(buffer) when is_binary(buffer), do: do_decode(buffer, [])

  def want_config_frame(nonce) when is_integer(nonce) and nonce > 0 do
    encode_frame(Protobuf.encode_varint_field(3, nonce))
  end

  def heartbeat_frame do
    # ToRadio.heartbeat = 7 (empty Heartbeat message).
    encode_frame(Protobuf.encode_message_field(7, <<>>))
  end

  def disconnect_frame do
    encode_frame(Protobuf.encode_bool_field(4, true))
  end

  def send_text_frame(opts) when is_map(opts) do
    to = Map.get(opts, :to, @broadcast)
    channel = Map.get(opts, :channel, 0)
    text = Map.fetch!(opts, :text)
    hop_limit = Map.get(opts, :hop_limit, 3)
    packet_id = Map.get(opts, :id) || packet_id()
    want_ack? = Map.get(opts, :want_ack, false)

    data =
      Protobuf.encode_varint_field(1, @port_text) <>
        Protobuf.encode_bytes_field(2, text)

    packet = mesh_packet(to, channel, data, packet_id, hop_limit, want_ack?)
    encode_frame(Protobuf.encode_message_field(1, packet))
  end

  def send_channel_text_frame(idx, text)
      when is_integer(idx) and idx in 0..7 and is_binary(text) do
    send_text_frame(%{to: @broadcast, channel: idx, text: text, want_ack: false})
  end

  def send_dm_text_frame(node_num, text)
      when is_integer(node_num) and is_binary(text) do
    send_text_frame(%{to: node_num, channel: 0, text: text, want_ack: true})
  end

  @doc """
  AdminMessage.get_channel_request is 1-based (index + 1) so protobuf never
  omits a zero.
  """
  def get_channel_admin_frame(node_num, idx)
      when is_integer(node_num) and is_integer(idx) and idx in 0..7 do
    admin = Protobuf.encode_varint_field(1, idx + 1)
    admin_packet_frame(node_num, admin, _want_response = true)
  end

  def set_channel_admin_frame(node_num, channel, session_passkey)
      when is_integer(node_num) and is_map(channel) do
    admin =
      Protobuf.encode_bytes_field(101, session_passkey || <<>>) <>
        Protobuf.encode_message_field(33, encode_channel(channel))

    admin_packet_frame(node_num, admin, false)
  end

  def get_config_admin_frame(node_num, :device)
      when is_integer(node_num) do
    admin = Protobuf.encode_varint_field(5, @config_device)
    admin_packet_frame(node_num, admin, true)
  end

  def get_config_admin_frame(node_num, :position)
      when is_integer(node_num) do
    admin = Protobuf.encode_varint_field(5, @config_position)
    admin_packet_frame(node_num, admin, true)
  end

  def get_config_admin_frame(node_num, :lora)
      when is_integer(node_num) do
    admin = Protobuf.encode_varint_field(5, @config_lora)
    admin_packet_frame(node_num, admin, true)
  end

  @doc """
  AdminMessage.set_time_only = 43 (`fixed32` Unix seconds, quality Net).
  Session passkey (field 101) comes from a prior get_config / get_channel.
  """
  def set_time_admin_frame(node_num, unix, session_passkey)
      when is_integer(node_num) and is_integer(unix) and unix >= 0 do
    admin =
      Protobuf.encode_bytes_field(101, session_passkey || <<>>) <>
        Protobuf.encode_fixed32_field(43, unix)

    admin_packet_frame(node_num, admin, false)
  end

  def set_config_lora_admin_frame(node_num, lora, session_passkey)
      when is_integer(node_num) and is_map(lora) do
    config = Protobuf.encode_message_field(6, encode_lora_config(lora))

    admin =
      Protobuf.encode_bytes_field(101, session_passkey || <<>>) <>
        Protobuf.encode_message_field(34, config)

    admin_packet_frame(node_num, admin, false)
  end

  def set_config_device_admin_frame(node_num, device, session_passkey)
      when is_integer(node_num) and is_map(device) do
    config = Protobuf.encode_message_field(1, encode_device_config(device))

    admin =
      Protobuf.encode_bytes_field(101, session_passkey || <<>>) <>
        Protobuf.encode_message_field(34, config)

    admin_packet_frame(node_num, admin, false)
  end

  def empty_device_config do
    %{
      role: 0,
      button_gpio: 0,
      buzzer_gpio: 0,
      rebroadcast_mode: 0,
      node_info_broadcast_secs: 0,
      double_tap_as_button_press: false,
      disable_triple_click: false,
      tzdef: "",
      led_heartbeat_disabled: false,
      buzzer_mode: 0
    }
  end

  def encode_device_config(device) when is_map(device) do
    role = Map.get(device, :role, 0)
    button = Map.get(device, :button_gpio, 0)
    buzzer = Map.get(device, :buzzer_gpio, 0)
    rebroadcast = Map.get(device, :rebroadcast_mode, 0)
    nodeinfo = Map.get(device, :node_info_broadcast_secs, 0)
    buzzer_mode = Map.get(device, :buzzer_mode, 0)

    maybe_varint(1, role, role != 0) <>
      maybe_varint(4, button, button != 0) <>
      maybe_varint(5, buzzer, buzzer != 0) <>
      maybe_varint(6, rebroadcast, rebroadcast != 0) <>
      maybe_varint(7, nodeinfo, nodeinfo != 0) <>
      maybe_bool(8, Map.get(device, :double_tap_as_button_press, false)) <>
      maybe_bool(10, Map.get(device, :disable_triple_click, false)) <>
      Protobuf.encode_bytes_field(11, Map.get(device, :tzdef, "") || "") <>
      maybe_bool(12, Map.get(device, :led_heartbeat_disabled, false)) <>
      maybe_varint(13, buzzer_mode, buzzer_mode != 0)
  end

  def parse_device_config(bin) when is_binary(bin) do
    fields = Protobuf.decode(bin)

    %{
      role: Protobuf.varint(fields, 1, 0),
      button_gpio: Protobuf.varint(fields, 4, 0),
      buzzer_gpio: Protobuf.varint(fields, 5, 0),
      rebroadcast_mode: Protobuf.varint(fields, 6, 0),
      node_info_broadcast_secs: Protobuf.varint(fields, 7, 0),
      double_tap_as_button_press: Protobuf.varint(fields, 8, 0) == 1,
      disable_triple_click: Protobuf.varint(fields, 10, 0) == 1,
      tzdef: Protobuf.bytes(fields, 11, ""),
      led_heartbeat_disabled: Protobuf.varint(fields, 12, 0) == 1,
      buzzer_mode: Protobuf.varint(fields, 13, 0)
    }
  end

  def parse_device_config(_), do: empty_device_config()

  def reboot_admin_frame(node_num, seconds \\ 2)
      when is_integer(node_num) and is_integer(seconds) and seconds > 0 do
    admin = Protobuf.encode_varint_field(97, seconds)
    admin_packet_frame(node_num, admin, false)
  end

  def encode_lora_config(lora) when is_map(lora) do
    use_preset? = Map.get(lora, :use_preset, true)
    tx_enabled? = Map.get(lora, :tx_enabled, true)

    Protobuf.encode_bool_explicit(1, use_preset?) <>
      maybe_varint(2, Map.get(lora, :modem_preset, 0), use_preset?) <>
      maybe_varint(3, Map.get(lora, :bandwidth, 0), not use_preset?) <>
      maybe_varint(4, Map.get(lora, :spread_factor, 0), not use_preset?) <>
      maybe_varint(5, Map.get(lora, :coding_rate, 0), not use_preset?) <>
      maybe_float(6, Map.get(lora, :frequency_offset, 0.0)) <>
      Protobuf.encode_varint_field(7, Map.get(lora, :region, 0)) <>
      Protobuf.encode_varint_field(8, Map.get(lora, :hop_limit, 3)) <>
      Protobuf.encode_bool_explicit(9, tx_enabled?) <>
      maybe_varint(10, Map.get(lora, :tx_power, 0), true) <>
      maybe_varint(11, Map.get(lora, :channel_num, 0), true) <>
      maybe_bool(12, Map.get(lora, :override_duty_cycle, false)) <>
      maybe_bool(13, Map.get(lora, :sx126x_rx_boosted_gain, false)) <>
      maybe_float(14, Map.get(lora, :override_frequency, 0.0)) <>
      maybe_bool(15, Map.get(lora, :pa_fan_disabled, false)) <>
      maybe_bool(104, Map.get(lora, :ignore_mqtt, false)) <>
      maybe_bool(105, Map.get(lora, :config_ok_to_mqtt, false))
  end

  def parse_lora_config(bin) when is_binary(bin) do
    fields = Protobuf.decode(bin)

    %{
      use_preset: Protobuf.varint(fields, 1, 0) == 1,
      modem_preset: Protobuf.varint(fields, 2, 0),
      bandwidth: Protobuf.varint(fields, 3, 0),
      spread_factor: Protobuf.varint(fields, 4, 0),
      coding_rate: Protobuf.varint(fields, 5, 0),
      frequency_offset: Protobuf.as_float32(Protobuf.field(fields, 6) || 0),
      region: Protobuf.varint(fields, 7, 0),
      hop_limit: Protobuf.varint(fields, 8, 3),
      tx_enabled: Protobuf.varint(fields, 9, 1) == 1,
      tx_power: Protobuf.varint(fields, 10, 0),
      channel_num: Protobuf.varint(fields, 11, 0),
      override_duty_cycle: Protobuf.varint(fields, 12, 0) == 1,
      sx126x_rx_boosted_gain: Protobuf.varint(fields, 13, 0) == 1,
      override_frequency: Protobuf.as_float32(Protobuf.field(fields, 14) || 0),
      pa_fan_disabled: Protobuf.varint(fields, 15, 0) == 1,
      ignore_mqtt: Protobuf.varint(fields, 104, 0) == 1,
      config_ok_to_mqtt: Protobuf.varint(fields, 105, 0) == 1
    }
  end

  def parse_config(bin) when is_binary(bin) do
    fields = Protobuf.decode(bin)

    cond do
      device = Protobuf.bytes(fields, 1) ->
        {:device, parse_device_config(device)}

      lora = Protobuf.bytes(fields, 6) ->
        {:lora, parse_lora_config(lora)}

      true ->
        {:other, fields}
    end
  end

  def encode_channel(%{index: idx} = ch) when is_integer(idx) do
    settings = encode_channel_settings(ch)
    role = Map.get(ch, :role, @role_secondary)

    Protobuf.encode_varint_field(1, idx) <>
      Protobuf.encode_message_field(2, settings) <>
      Protobuf.encode_varint_field(3, role)
  end

  def encode_channel_settings(ch) when is_map(ch) do
    psk = Map.get(ch, :psk) || psk_from_hex(Map.get(ch, :psk_hex) || Map.get(ch, :secret_hex))
    name = Map.get(ch, :name) || ""
    id = Map.get(ch, :channel_id) || :rand.uniform(0xFFFFFFFE) + 1
    role = Map.get(ch, :role, @role_secondary)

    psk_bin = psk || <<>>

    psk_field =
      if role == @role_disabled,
        do: Protobuf.encode_bytes_explicit(2, psk_bin),
        else: Protobuf.encode_bytes_field(2, psk_bin)

    name_field =
      if role == @role_disabled,
        do: Protobuf.encode_bytes_explicit(3, name),
        else: Protobuf.encode_bytes_field(3, name)

    psk_field <> name_field <> Protobuf.encode_fixed32_field(4, id)
  end

  @doc "ChannelSet protobuf used by `https://meshtastic.org/e/#…` invite URLs."
  def encode_channel_set(ch) when is_map(ch) do
    Protobuf.encode_message_field(1, encode_channel_settings(ch))
  end

  def channel_invite_uri(ch) when is_map(ch) do
    payload =
      ch
      |> encode_channel_set()
      |> Base.url_encode64(padding: false)

    "https://meshtastic.org/e/#" <> payload <> "?add=true"
  end

  def parse_frame(payload) when is_binary(payload) do
    fields = Protobuf.decode(payload)

    cond do
      packet = Protobuf.bytes(fields, 2) ->
        {:packet, parse_mesh_packet(packet)}

      my_info = Protobuf.bytes(fields, 3) ->
        {:my_info, parse_my_info(my_info)}

      node_info = Protobuf.bytes(fields, 4) ->
        {:node_info, parse_node_info(node_info)}

      complete = Protobuf.field(fields, 7) ->
        {:config_complete, complete}

      Protobuf.varint(fields, 8, 0) == 1 ->
        :rebooted

      channel = Protobuf.bytes(fields, 10) ->
        {:channel, parse_channel(channel)}

      config = Protobuf.bytes(fields, 5) ->
        {:config, parse_config(config)}

      true ->
        {:other, fields}
    end
  end

  def parse_mesh_packet(bin) when is_binary(bin) do
    fields = Protobuf.decode(bin)
    from = Protobuf.field(fields, 1) || 0
    to = Protobuf.field(fields, 2) || 0
    channel = Protobuf.varint(fields, 3, 0)
    decoded = Protobuf.nested(fields, 4)
    portnum = Protobuf.varint(decoded, 1, 0)
    payload = Protobuf.bytes(decoded, 2, <<>>)

    hop_limit = Protobuf.varint(fields, 9, 0)
    hop_start = Protobuf.varint(fields, 14, 0)

    hops =
      if hop_start > 0 and hop_limit <= hop_start do
        hop_start - hop_limit
      end

    %{
      from: from,
      to: to,
      channel: channel,
      id: Protobuf.field(fields, 6),
      portnum: portnum,
      payload: payload,
      want_response: Protobuf.varint(decoded, 3, 0) == 1,
      snr: Protobuf.as_float32(Protobuf.field(fields, 8) || 0),
      hop_limit: hop_limit,
      hop_start: hop_start,
      hops: hops
    }
  end

  def parse_admin_payload(payload) when is_binary(payload) do
    fields = Protobuf.decode(payload)
    passkey = Protobuf.bytes(fields, 101, <<>>)

    cond do
      ch = Protobuf.bytes(fields, 2) ->
        {:get_channel_response, parse_channel(ch), passkey}

      cfg = Protobuf.bytes(fields, 6) ->
        {:get_config_response, parse_config(cfg), passkey}

      true ->
        {:other, fields, passkey}
    end
  end

  def parse_channel(bin) when is_binary(bin) do
    fields = Protobuf.decode(bin)
    settings = Protobuf.nested(fields, 2)
    psk = Protobuf.bytes(settings, 2, <<>>)
    name = Protobuf.bytes(settings, 3, "")
    role = Protobuf.varint(fields, 3, @role_disabled)
    idx = Protobuf.varint(fields, 1, 0)

    empty? = role == @role_disabled or (name == "" and psk in [<<>>, <<0>>])

    %{
      index: idx,
      name: name,
      psk: psk,
      psk_hex: Base.encode16(psk, case: :lower),
      secret_hex: Base.encode16(psk, case: :lower),
      channel_id: Protobuf.field(settings, 4),
      role: role,
      empty?: empty?
    }
  end

  def parse_my_info(bin) when is_binary(bin) do
    fields = Protobuf.decode(bin)
    num = Protobuf.varint(fields, 1, 0)

    %{
      my_node_num: num,
      node_id: node_id_hex(num),
      reboot_count: Protobuf.varint(fields, 8, 0),
      min_app_version: Protobuf.varint(fields, 11, 0)
    }
  end

  def parse_node_info(bin) when is_binary(bin) do
    fields = Protobuf.decode(bin)
    num = Protobuf.varint(fields, 1, 0)
    user = parse_user(Protobuf.bytes(fields, 2, <<>>))
    node_id = if num > 0, do: node_id_hex(num), else: user.node_id

    position = Protobuf.nested(fields, 3)

    %{
      num: num,
      node_id: node_id,
      name: user.name,
      short_name: user.short_name,
      user: user,
      snr: Protobuf.as_float32(Protobuf.field(fields, 4) || 0),
      last_heard: protobuf_unix(Protobuf.field(fields, 5)),
      position_time: protobuf_unix(Protobuf.field(position, 4)),
      hops: Protobuf.varint(fields, 9, 0)
    }
  end

  @doc "Position.time = 4 (`fixed32` seconds since 1970)."
  def parse_position(bin) when is_binary(bin) do
    fields = Protobuf.decode(bin)
    %{time: protobuf_unix(Protobuf.field(fields, 4))}
  end

  def parse_position(_), do: %{time: 0}

  @doc "Telemetry.time = 1 (`fixed32` seconds since 1970)."
  def parse_telemetry_time(bin) when is_binary(bin) do
    protobuf_unix(Protobuf.field(Protobuf.decode(bin), 1))
  end

  def parse_telemetry_time(_), do: 0

  defp protobuf_unix(n) when is_integer(n) and n > 0, do: n
  defp protobuf_unix(_), do: 0

  def parse_user(bin) when is_binary(bin) do
    fields = Protobuf.decode(bin)
    id = Protobuf.bytes(fields, 1, "") |> sanitize_user_string()
    long_name = Protobuf.bytes(fields, 2, "") |> sanitize_user_string()
    short_name = Protobuf.bytes(fields, 3, "") |> sanitize_user_string()

    node_id =
      case parse_node_id(id) do
        {:ok, n} -> node_id_hex(n)
        :error -> nil
      end

    name =
      cond do
        long_name != "" -> long_name
        short_name != "" -> short_name
        true -> nil
      end

    %{
      id: id,
      node_id: node_id,
      name: name,
      long_name: long_name,
      short_name: short_name
    }
  end

  def parse_user(_), do: %{id: "", node_id: nil, name: nil, long_name: "", short_name: ""}

  defp sanitize_user_string(bin) when is_binary(bin) do
    if String.valid?(bin), do: String.trim(bin), else: ""
  end

  defp sanitize_user_string(_), do: ""

  def node_id_hex(num) when is_integer(num) do
    num
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(8, "0")
  end

  def parse_node_id(ref) when is_binary(ref) do
    cleaned =
      ref
      |> String.trim()
      |> String.trim_leading("!")
      |> String.downcase()

    case Integer.parse(cleaned, 16) do
      {n, ""} when n >= 0 and n <= 0xFFFFFFFF -> {:ok, n}
      _ -> :error
    end
  end

  def psk_from_hex(nil), do: nil

  def psk_from_hex(hex) when is_binary(hex) do
    case Base.decode16(String.downcase(hex), case: :lower) do
      {:ok, bin} -> bin
      :error -> nil
    end
  end

  defp admin_packet_frame(node_num, admin, want_response?) do
    data =
      Protobuf.encode_varint_field(1, @port_admin) <>
        Protobuf.encode_bytes_field(2, admin) <>
        Protobuf.encode_bool_field(3, want_response?)

    packet = mesh_packet(node_num, 0, data, packet_id(), 0, false)
    encode_frame(Protobuf.encode_message_field(1, packet))
  end

  defp mesh_packet(to, channel, data, packet_id, hop_limit, want_ack?) do
    Protobuf.encode_fixed32_field(2, to) <>
      Protobuf.encode_varint_field(3, channel) <>
      Protobuf.encode_message_field(4, data) <>
      Protobuf.encode_fixed32_field(6, packet_id) <>
      Protobuf.encode_varint_field(9, hop_limit) <>
      Protobuf.encode_bool_field(10, want_ack?)
  end

  defp packet_id do
    <<n::little-unsigned-32>> = :crypto.strong_rand_bytes(4)
    if n == 0, do: 1, else: n
  end

  defp maybe_varint(_field, _value, false), do: <<>>

  defp maybe_varint(field, value, true) when is_integer(value) and value >= 0 do
    Protobuf.encode_varint_field(field, value)
  end

  defp maybe_bool(_field, false), do: <<>>
  defp maybe_bool(field, true), do: Protobuf.encode_varint_field(field, 1)

  defp maybe_float(_field, n) when is_number(n) and n == 0, do: <<>>
  defp maybe_float(field, n) when is_number(n), do: Protobuf.encode_float_field(field, n * 1.0)

  defp do_decode(<<@start1, @start2, len::big-16, payload::binary-size(len), rest::binary>>, acc)
       when len <= @max_frame do
    do_decode(rest, [payload | acc])
  end

  defp do_decode(<<@start1, @start2, len::big-16, _::binary>> = buffer, acc)
       when byte_size(buffer) < len + 4 do
    {Enum.reverse(acc), buffer}
  end

  defp do_decode(<<@start1, @start2, len::big-16, _::binary>> = buffer, acc)
       when len > @max_frame do
    # Resync past a bogus length.
    <<_, rest::binary>> = buffer
    do_decode(rest, acc)
  end

  defp do_decode(<<@start1, @start2, _::binary>> = buffer, acc)
       when byte_size(buffer) < 4 do
    {Enum.reverse(acc), buffer}
  end

  defp do_decode(<<@start1>>, acc), do: {Enum.reverse(acc), <<@start1>>}

  defp do_decode(<<@start1, b, rest::binary>>, acc) when b != @start2 do
    do_decode(<<b, rest::binary>>, acc)
  end

  defp do_decode(<<_, rest::binary>>, acc), do: do_decode(rest, acc)
  defp do_decode(<<>>, acc), do: {Enum.reverse(acc), <<>>}
end
