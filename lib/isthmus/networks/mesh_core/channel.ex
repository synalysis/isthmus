defmodule Isthmus.Networks.MeshCore.Channel do
  @moduledoc """
  MeshCore group-channel helpers for tunnel filtering.

  Group text/data packets carry a 1-byte channel hash (first byte of
  SHA-256 of the 16-byte channel PSK). The firmware default **Public**
  channel uses a well-known PSK published in the MeshCore companion spec.
  """

  alias Isthmus.Networks.MeshCore.Packet

  # Default Public channel PSK (16 bytes), MeshCore companion protocol.
  @public_psk_hex "8b3387e9c5cdea6ac9e5edbaa115cd72"

  @type_grp_txt 0x05
  @type_grp_data 0x06

  def type_grp_txt, do: @type_grp_txt
  def type_grp_data, do: @type_grp_data

  def public_psk do
    Base.decode16!(@public_psk_hex, case: :lower)
  end

  def public_psk_hex, do: @public_psk_hex

  @doc "First byte of SHA-256(Public PSK) — channel hash on the wire."
  def public_channel_hash do
    :crypto.hash(:sha256, public_psk()) |> :binary.first()
  end

  @doc """
  True when `packet` is GRP_TXT/GRP_DATA for the default Public channel.

  Matches on the channel-hash byte only (MeshCore's own selector); does not
  decrypt. A 1-byte hash can theoretically collide with another PSK.
  """
  def public_group_packet?(packet) when is_binary(packet) do
    case Packet.decode(packet) do
      {:ok, decoded} -> public_group_packet?(decoded)
      _ -> false
    end
  end

  def public_group_packet?(%{payload_type: type, payload: <<hash, _::binary>>})
      when type in [@type_grp_txt, @type_grp_data] do
    hash == public_channel_hash()
  end

  def public_group_packet?(_), do: false
end
