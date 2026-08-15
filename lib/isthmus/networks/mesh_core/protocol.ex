defmodule Isthmus.Networks.MeshCore.Protocol do
  @moduledoc """
  Companion Radio Protocol framing (USB).

  Outbound (app -> radio): `<` + len(le16) + frame
  Inbound  (radio -> app): `>` + len(le16) + frame
  """

  @cmd_app_start 1
  @cmd_send_txt_msg 2
  @cmd_send_channel_txt_msg 3
  @cmd_get_contacts 4
  @cmd_send_self_advert 7
  @cmd_sync_next_message 10
  @cmd_set_radio_params 11
  @cmd_set_radio_tx_power 12
  @cmd_reset_path 13
  @cmd_device_query 22
  @cmd_send_raw_data 25
  @cmd_get_channel 0x1F
  @cmd_set_channel 0x20

  @resp_ok 0
  @resp_err 1
  @resp_contacts_start 2
  @resp_contact 3
  @resp_end_of_contacts 4
  @resp_self_info 5
  @resp_sent 6
  @resp_contact_msg_recv 7
  @resp_channel_msg_recv 0x08
  @resp_no_more_messages 10
  @resp_device_info 13
  @resp_contact_msg_recv_v3 16
  @resp_channel_msg_recv_v3 0x11
  @resp_channel_info 0x12

  @push_advert 0x80
  @push_path_updated 0x81
  @push_msg_waiting 0x83
  @push_raw_data 0x84

  def cmd_app_start, do: @cmd_app_start
  def cmd_device_query, do: @cmd_device_query
  def cmd_send_raw_data, do: @cmd_send_raw_data
  def push_raw_data, do: @push_raw_data

  def encode_usb_frame(frame) when is_binary(frame) do
    <<"<", byte_size(frame)::little-16, frame::binary>>
  end

  @doc "USB wraps frames; BLE sends one raw companion frame per GATT write."
  def encode_outbound(:ble, frame) when is_binary(frame), do: frame
  def encode_outbound(_usb, frame) when is_binary(frame), do: encode_usb_frame(frame)

  def decode_usb_stream(buffer) when is_binary(buffer) do
    do_decode(buffer, [])
  end

  @doc """
  True when `frame` is a DEVICE_QUERY reply with a plausible DEVICE_INFO payload.

  RESP_DEVICE_INFO is code `0x0D` (CR). ESP32 boot logs often contain `>` and
  CR, which is enough for `decode_usb_stream/1` + `parse_frame/1` to report
  `:device_info`. SELF_INFO (`0x05`) is the APP_START reply, not DEVICE_QUERY.
  """
  def companion_probe_reply?(frame) when is_binary(frame) do
    case parse_frame(frame) do
      {:device_info, rest} -> plausible_device_info?(rest)
      _ -> false
    end
  end

  def companion_probe_reply?(_), do: false

  # fw >= 3 DEVICE_INFO is ~80 bytes (contacts, channels, BLE pin, strings).
  # fw 1–2 is shorter but still has the three-byte header.
  defp plausible_device_info?(<<fw, _contacts, channels, _::binary>> = rest)
       when fw in 3..8 and channels in 1..16 and byte_size(rest) >= 40 do
    true
  end

  defp plausible_device_info?(<<fw, _contacts, channels, _::binary>>)
       when fw in 1..2 and channels in 1..16 do
    true
  end

  defp plausible_device_info?(_), do: false

  defp do_decode(<<">", len::little-16, frame::binary-size(len), rest::binary>>, acc) do
    do_decode(rest, [frame | acc])
  end

  defp do_decode(buffer, acc), do: {Enum.reverse(acc), buffer}

  # CMD_DEVICE_QUERY — byte1 is app protocol version the host understands.
  # Companion ignores the command unless len >= 2 (see MeshCore MyMesh::handleCmdFrame).
  def device_query_frame(app_ver \\ 3)

  def device_query_frame(app_ver) when is_integer(app_ver) and app_ver in 0..255 do
    <<@cmd_device_query, app_ver>>
  end

  # CMD_APP_START — bytes 1..7 reserved; null-terminated app name starts at offset 8.
  def app_start_frame(name \\ "Isthmus") when is_binary(name) do
    <<@cmd_app_start, 0::unit(8)-size(7), name::binary, 0>>
  end

  def sync_next_message_frame, do: <<@cmd_sync_next_message>>
  def get_contacts_frame, do: <<@cmd_get_contacts>>

  def get_contacts_since_frame(since) when is_integer(since) do
    <<@cmd_get_contacts, since::little-32>>
  end

  def reset_path_frame(pubkey_bin) when byte_size(pubkey_bin) == 32 do
    <<@cmd_reset_path, pubkey_bin::binary-32>>
  end

  @doc """
  CMD_SEND_SELF_ADVERT — optional flood byte (1 = flood, 0/absent = zero-hop).
  """
  def send_self_advert_frame(flood? \\ false)
  def send_self_advert_frame(true), do: <<@cmd_send_self_advert, 1>>
  def send_self_advert_frame(_), do: <<@cmd_send_self_advert, 0>>

  def send_raw_frame(path_len, path, payload)
      when is_integer(path_len) and is_binary(path) and is_binary(payload) do
    <<@cmd_send_raw_data, path_len::signed-8, path::binary, payload::binary>>
  end

  @doc """
  CMD_SEND_TXT_MSG — pubkey(32) + timestamp(uint32) + attempt(byte) + text
  """
  def send_txt_msg_frame(pubkey_bin, text)
      when byte_size(pubkey_bin) == 32 and is_binary(text) do
    ts = System.system_time(:second)
    <<@cmd_send_txt_msg, pubkey_bin::binary-32, ts::little-32, 0, text::binary>>
  end

  @doc "CMD_GET_CHANNEL — channel index (0-7)."
  def get_channel_frame(idx) when is_integer(idx) and idx in 0..7 do
    <<@cmd_get_channel, idx>>
  end

  @doc "CMD_SET_CHANNEL — index + name (32 bytes padded) + secret (16 bytes)."
  def set_channel_frame(idx, name, secret)
      when is_integer(idx) and idx in 0..7 and is_binary(name) and is_binary(secret) do
    name_bin = pad_name(name, 32)
    secret_bin = pad_secret(secret, 16)
    <<@cmd_set_channel, idx, name_bin::binary, secret_bin::binary>>
  end

  @doc """
  CMD_SET_RADIO_PARAMS — freq and bw as unsigned LE int (MHz×1000 / kHz×1000),
  then sf (5–12) and cr (5–8).
  """
  def set_radio_params_frame(freq_mhz, bw_khz, sf, cr)
      when is_number(freq_mhz) and is_number(bw_khz) and sf in 5..12 and cr in 5..8 do
    freq_u = round(freq_mhz * 1000)
    bw_u = round(bw_khz * 1000)
    <<@cmd_set_radio_params, freq_u::little-32, bw_u::little-32, sf, cr>>
  end

  @doc "CMD_SET_RADIO_TX_POWER — tx power in dBm."
  def set_tx_power_frame(tx_dbm) when is_integer(tx_dbm) and tx_dbm in 0..30 do
    <<@cmd_set_radio_tx_power, tx_dbm>>
  end

  @doc "CMD_SEND_CHANNEL_TXT_MSG — txt_type(0) + channel_idx + timestamp + text."
  def send_channel_txt_frame(idx, text)
      when is_integer(idx) and idx in 0..7 and is_binary(text) do
    ts = System.system_time(:second)
    <<@cmd_send_channel_txt_msg, 0, idx, ts::little-32, text::binary>>
  end

  def parse_frame(<<@resp_ok>>), do: {:ok, :ok}
  def parse_frame(<<@resp_err, _::binary>>), do: {:error, :remote}
  def parse_frame(<<@resp_contacts_start, count::little-32>>), do: {:contacts_start, count}
  def parse_frame(<<@resp_end_of_contacts, lastmod::little-32>>), do: {:end_of_contacts, lastmod}
  def parse_frame(<<@resp_end_of_contacts>>), do: {:end_of_contacts, 0}

  def parse_frame(
        <<@resp_contact, public_key::binary-32, type, flags, out_path_len::signed-8,
          out_path::binary-64, adv_name::binary-32, last_advert::little-32,
          adv_lat::signed-little-32, adv_lon::signed-little-32, lastmod::little-32>>
      ) do
    path_len = if out_path_len < 0, do: 0, else: min(out_path_len, 64)
    path = binary_part(out_path, 0, path_len)
    hops = if out_path_len < 0, do: nil, else: path_len

    {:contact,
     %{
       public_key: Base.encode16(public_key, case: :lower),
       type: type,
       flags: flags,
       out_path_len: path_len,
       out_path: path,
       out_path_hex: Base.encode16(path, case: :lower),
       hops: hops,
       name: null_term_string(adv_name),
       last_advert: last_advert,
       adv_lat: adv_lat,
       adv_lon: adv_lon,
       lastmod: lastmod
     }}
  end

  def parse_frame(<<@resp_channel_info, idx, name::binary-32, secret::binary-16>>) do
    {:channel_info, channel_info_map(idx, name, secret)}
  end

  def parse_frame(
        <<@resp_channel_msg_recv, idx, _path_len, txt_type, ts::little-32, text::binary>>
      ) do
    {:channel_msg,
     %{
       channel_idx: idx,
       timestamp: ts,
       txt_type: txt_type,
       body: text
     }}
  end

  def parse_frame(
        <<@resp_channel_msg_recv_v3, snr, _reserved::binary-2, idx, _path_len, txt_type,
          ts::little-32, text::binary>>
      ) do
    {:channel_msg,
     %{
       channel_idx: idx,
       timestamp: ts,
       txt_type: txt_type,
       snr: snr,
       body: text
     }}
  end

  def parse_frame(<<@resp_device_info, rest::binary>>), do: {:device_info, rest}

  # SELF_INFO is the firmware's reply to CMD_APP_START and carries this node's
  # own public key: [adv_type][tx_power][max_tx_power][pub_key x32][lat x4]...
  def parse_frame(
        <<@resp_self_info, adv_type, tx_power, max_tx_power, pubkey::binary-32, rest::binary>>
      ) do
    radio = parse_self_info_radio(rest)

    {:self_info,
     Map.merge(
       %{
         adv_type: adv_type,
         tx_power: tx_power,
         max_tx_power: max_tx_power,
         public_key: Base.encode16(pubkey, case: :lower),
         name: self_info_name(rest)
       },
       radio
     )}
  end

  def parse_frame(<<@resp_self_info, rest::binary>>), do: {:self_info, %{raw: rest}}
  def parse_frame(<<@resp_sent, ack::little-32>>), do: {:sent, ack}
  def parse_frame(<<@resp_no_more_messages>>), do: {:no_more_messages, true}
  def parse_frame(<<@push_raw_data, rest::binary>>), do: {:raw_data, rest}
  def parse_frame(<<@push_msg_waiting, _::binary>>), do: {:msg_waiting, true}

  def parse_frame(<<@push_path_updated, pubkey::binary-32>>),
    do: {:path_updated, Base.encode16(pubkey, case: :lower)}

  def parse_frame(<<@push_advert, pubkey::binary-32>>),
    do: {:advert, Base.encode16(pubkey, case: :lower)}

  def parse_frame(<<@push_advert, rest::binary>>) when byte_size(rest) >= 32 do
    <<pubkey::binary-32, _::binary>> = rest
    {:advert, Base.encode16(pubkey, case: :lower)}
  end

  def parse_frame(
        <<@resp_contact_msg_recv, pubkey::binary-32, ts::little-32, txt_type, text::binary>>
      ) do
    {:contact_msg,
     %{
       from_ref: Base.encode16(pubkey, case: :lower),
       timestamp: ts,
       txt_type: txt_type,
       body: text
     }}
  end

  def parse_frame(
        <<@resp_contact_msg_recv_v3, pubkey::binary-32, ts::little-32, txt_type, snr, score,
          text::binary>>
      ) do
    {:contact_msg,
     %{
       from_ref: Base.encode16(pubkey, case: :lower),
       timestamp: ts,
       txt_type: txt_type,
       snr: snr,
       score: score,
       body: text
     }}
  end

  def parse_frame(<<code, rest::binary>>), do: {:unknown, code, rest}
  def parse_frame(_), do: {:error, :empty}

  # After the public key SELF_INFO carries lat/lon, four policy bytes and the
  # radio params (22 bytes) before the node name. Older firmware truncates.
  defp self_info_name(<<_::binary-22, name::binary>>), do: null_term_string(name)
  defp self_info_name(_), do: nil

  defp parse_self_info_radio(
         <<_lat::little-signed-32, _lon::little-signed-32, _multi, _loc, _telem, _manual,
           freq::little-32, bw::little-32, sf, cr, _::binary>>
       ) do
    %{
      freq_mhz: freq / 1000.0,
      bw_khz: bw / 1000.0,
      sf: sf,
      cr: cr
    }
  end

  defp parse_self_info_radio(_), do: %{}

  defp null_term_string(bin) when is_binary(bin) do
    case :binary.split(bin, <<0>>) do
      [name | _] -> String.trim(name)
      _ -> ""
    end
  end

  defp pad_name(name, size) when is_binary(name) and is_integer(size) do
    name = String.slice(name, 0, size)
    pad = size - byte_size(name)
    name <> :binary.copy(<<0>>, pad)
  end

  defp pad_secret(secret, size) when is_binary(secret) and is_integer(size) do
    cond do
      byte_size(secret) == size -> secret
      byte_size(secret) > size -> binary_part(secret, 0, size)
      true -> secret <> :binary.copy(<<0>>, size - byte_size(secret))
    end
  end

  defp channel_info_map(idx, name_bin, secret_bin) do
    name = null_term_string(name_bin)
    secret_hex = Base.encode16(secret_bin, case: :lower)
    empty? = name == "" and zero_secret?(secret_bin)

    %{
      index: idx,
      name: name,
      secret_hex: secret_hex,
      empty?: empty?
    }
  end

  defp zero_secret?(<<>>), do: true

  defp zero_secret?(bin) when is_binary(bin) do
    Enum.all?(:binary.bin_to_list(bin), &(&1 == 0))
  end
end
