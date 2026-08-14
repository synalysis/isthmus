defmodule Isthmus.Tunnel.Frame do
  @moduledoc """
  Shared tunnel framing for opaque island bridging.

      magic | version | tunnel_id | flags | frag_idx | frag_cnt | seq | mac16 | payload

  `mac16` is HMAC-SHA256 truncated to 16 bytes over the authenticated header
  and this fragment's payload. Version 2 frames require a MAC key derived from
  the pairing code (or, for legacy tunnel-id-only peers, from the tunnel id).
  """

  @magic <<"ISTH">>
  @version 2
  @max_frag_cnt 32
  @max_payload 65_536

  @flag_ack 0x01
  @flag_control 0x02
  @flag_data 0x04

  def flag_ack, do: @flag_ack
  def flag_control, do: @flag_control
  def flag_data, do: @flag_data
  def version, do: @version
  def max_frag_cnt, do: @max_frag_cnt

  @type t :: %__MODULE__{
          version: non_neg_integer(),
          tunnel_id: binary(),
          flags: non_neg_integer(),
          frag_idx: non_neg_integer(),
          frag_cnt: non_neg_integer(),
          seq: non_neg_integer(),
          payload_hash16: binary(),
          payload: binary()
        }

  defstruct version: @version,
            tunnel_id: <<0::128>>,
            flags: @flag_data,
            frag_idx: 0,
            frag_cnt: 1,
            seq: 0,
            payload_hash16: <<0::128>>,
            payload: <<>>

  def hash16(payload) when is_binary(payload) do
    :crypto.hash(:sha256, payload) |> binary_part(0, 16)
  end

  def tunnel_id_from_string(id) when is_binary(id) do
    case Base.decode16(id, case: :mixed) do
      {:ok, bin} when byte_size(bin) == 16 -> bin
      _ -> :crypto.hash(:sha256, id) |> binary_part(0, 16)
    end
  end

  @doc "HMAC-SHA256/16 of the authenticated fields for this fragment."
  def mac16(mac_key, %__MODULE__{} = frame) when is_binary(mac_key) do
    :crypto.mac(:hmac, :sha256, mac_key, mac_input(frame)) |> binary_part(0, 16)
  end

  @doc "True when `payload_hash16` matches HMAC(mac_key, frame)."
  def valid_mac?(%__MODULE__{} = frame, mac_key) when is_binary(mac_key) do
    expected = mac16(mac_key, frame)
    given = pad16(frame.payload_hash16)
    byte_size(expected) == byte_size(given) and Plug.Crypto.secure_compare(expected, given)
  end

  def valid_mac?(_, _), do: false

  def encode(%__MODULE__{} = frame, mac_key) when is_binary(mac_key) do
    frame = %{frame | version: @version, payload_hash16: mac16(mac_key, frame)}
    tunnel_id = pad16(frame.tunnel_id)
    mac = pad16(frame.payload_hash16)

    @magic <>
      <<frame.version::8, tunnel_id::binary-16, frame.flags::8, frame.frag_idx::16,
        frame.frag_cnt::16, frame.seq::32, mac::binary-16, byte_size(frame.payload)::32,
        frame.payload::binary>>
  end

  def decode(
        <<@magic, version::8, tunnel_id::binary-16, flags::8, frag_idx::16, frag_cnt::16, seq::32,
          hash::binary-16, plen::32, payload::binary-size(plen), rest::binary>>
      )
      when plen <= @max_payload and frag_cnt > 0 and frag_cnt <= @max_frag_cnt and
             frag_idx < frag_cnt do
    frame = %__MODULE__{
      version: version,
      tunnel_id: tunnel_id,
      flags: flags,
      frag_idx: frag_idx,
      frag_cnt: frag_cnt,
      seq: seq,
      payload_hash16: hash,
      payload: payload
    }

    {:ok, frame, rest}
  end

  def decode(_), do: {:error, :invalid_frame}

  @header_size 50

  @doc "Split payload into MTU-sized frames."
  def fragment(tunnel_id, seq, payload, mtu) when mtu > @header_size + 8 do
    max_payload = mtu - @header_size
    chunks = chunk(payload, max_payload)
    count = max(length(chunks), 1)

    if count > @max_frag_cnt do
      raise ArgumentError, "tunnel payload needs #{count} fragments (max #{@max_frag_cnt})"
    end

    chunks
    |> Enum.with_index()
    |> Enum.map(fn {chunk, idx} ->
      %__MODULE__{
        version: @version,
        tunnel_id: pad16(tunnel_id),
        flags: @flag_data,
        frag_idx: idx,
        frag_cnt: count,
        seq: seq,
        payload_hash16: <<0::128>>,
        payload: chunk
      }
    end)
  end

  def ack_frame(tunnel_id, seq) do
    %__MODULE__{
      version: @version,
      tunnel_id: pad16(tunnel_id),
      flags: @flag_ack,
      frag_idx: 0,
      frag_cnt: 1,
      seq: seq,
      payload_hash16: <<0::128>>,
      payload: <<>>
    }
  end

  @doc "Single control-plane frame (announce fan-out, etc.)."
  def control_frame(tunnel_id, seq, payload) when is_binary(payload) do
    %__MODULE__{
      version: @version,
      tunnel_id: pad16(tunnel_id),
      flags: @flag_control,
      frag_idx: 0,
      frag_cnt: 1,
      seq: seq,
      payload_hash16: <<0::128>>,
      payload: payload
    }
  end

  defp mac_input(%__MODULE__{} = frame) do
    tunnel_id = pad16(frame.tunnel_id)

    <<@version::8, tunnel_id::binary-16, frame.flags::8, frame.frag_idx::16, frame.frag_cnt::16,
      frame.seq::32, byte_size(frame.payload)::32, frame.payload::binary>>
  end

  defp chunk(<<>>, _size), do: [<<>>]
  defp chunk(bin, size) when byte_size(bin) <= size, do: [bin]

  defp chunk(bin, size) do
    <<part::binary-size(^size), rest::binary>> = bin
    [part | chunk(rest, size)]
  end

  defp pad16(bin) when byte_size(bin) == 16, do: bin
  defp pad16(bin) when byte_size(bin) < 16, do: bin <> <<0::size((16 - byte_size(bin)) * 8)>>
  defp pad16(bin), do: binary_part(bin, 0, 16)
end
