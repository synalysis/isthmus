defmodule Isthmus.Networks.MeshCore.Channel do
  @moduledoc """
  MeshCore group-channel helpers for tunnel filtering.

  Group text/data packets (`GRP_TXT` / `GRP_DATA`) carry a 1-byte channel hash
  (first byte of SHA-256 of the 16-byte channel PSK). The firmware default
  **Public** channel uses a well-known PSK published in the MeshCore companion
  spec.
  """

  alias Isthmus.Networks.MeshCore.Crypto
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

  @doc "True for any GRP_TXT / GRP_DATA packet (any channel hash)."
  def group_packet?(packet) when is_binary(packet) do
    case Packet.decode(packet) do
      {:ok, decoded} -> group_packet?(decoded)
      _ -> false
    end
  end

  def group_packet?(%{payload_type: type, payload: <<_::binary-size(1), _::binary>>})
      when type in [@type_grp_txt, @type_grp_data],
      do: true

  def group_packet?(_), do: false

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

  @doc "True when a companion channel slot is the well-known Public channel."
  def public_slot?(slot) when is_map(slot) do
    name = slot[:name] || slot["name"] || ""
    secret = slot[:secret_hex] || slot["secret_hex"] || ""

    String.downcase(String.trim(to_string(name))) == "public" or
      String.downcase(to_string(secret)) == @public_psk_hex
  end

  def public_slot?(_), do: false

  @doc """
  Decrypt a Public GRP_TXT packet.

  Tries the 16-byte PSK zero-padded to 32 bytes (companion secret layout),
  then SHA-256(PSK) as the 32-byte channel secret.
  """
  def decrypt_public_text(packet) when is_binary(packet) do
    if public_group_packet?(packet) do
      decrypt_group_text(packet, public_psk())
    else
      :error
    end
  end

  def decrypt_public_text(_), do: :error

  def decrypt_group_text(packet, psk) when is_binary(packet) and is_binary(psk) do
    with {:ok, decoded} <- Packet.decode(packet),
         true <- decoded.payload_type == @type_grp_txt,
         <<_hash, wire::binary>> <- decoded.payload,
         {:ok, plain} <- try_mac_decrypt(psk, wire),
         <<ts::little-32, _flags, rest::binary>> <- trim_zeros(plain) do
      text = trim_zeros(rest) |> String.trim_trailing(<<0>>) |> String.trim()
      {name, body} = split_sender(text)
      hash = Packet.packet_hash(decoded) |> Base.encode16(case: :lower)

      {:ok,
       %{
         timestamp: ts,
         name: name,
         text: body,
         body: text,
         external_id: "mc-pub-#{hash}"
       }}
    else
      _ -> :error
    end
  end

  def decrypt_group_text(_, _), do: :error

  @doc "Build a GRP_TXT flood packet (tests / inject)."
  def build_group_text(psk, name, text, opts \\ []) when is_binary(psk) do
    ts = Keyword.get(opts, :timestamp, System.os_time(:second))
    inner = <<ts::little-32, 0>> <> "#{name}: #{text}"
    secret = channel_secret(psk)
    hash = :crypto.hash(:sha256, psk) |> :binary.first()
    payload = <<hash>> <> Crypto.encrypt_then_mac(secret, inner)

    Packet.build(Packet.route_flood(), @type_grp_txt, 0, <<>>, payload)
    |> Packet.encode()
  end

  defp try_mac_decrypt(psk, wire) do
    Enum.find_value([channel_secret(psk), :crypto.hash(:sha256, psk)], :error, fn secret ->
      case Crypto.mac_then_decrypt(secret, wire) do
        {:ok, plain} -> {:ok, plain}
        :error -> nil
      end
    end)
  end

  defp channel_secret(psk) when byte_size(psk) == 16, do: psk <> <<0::128>>
  defp channel_secret(psk) when byte_size(psk) == 32, do: psk

  defp channel_secret(psk) when is_binary(psk) and byte_size(psk) < 32 do
    psk <> :binary.copy(<<0>>, 32 - byte_size(psk))
  end

  defp channel_secret(_), do: <<0::256>>

  defp trim_zeros(bin) when is_binary(bin) do
    String.trim_trailing(bin, <<0>>)
  end

  defp split_sender(body) when is_binary(body) do
    case String.split(body, ": ", parts: 2) do
      [name, text] when name != "" -> {String.trim(name), String.trim(text)}
      _ -> {nil, String.trim(body)}
    end
  end
end
