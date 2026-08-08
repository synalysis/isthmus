defmodule Isthmus.Networks.MeshCore.Advert do
  @moduledoc "Build and parse MeshCore ADVERT payloads."

  alias Isthmus.Networks.MeshCore.Crypto
  alias Isthmus.Networks.MeshCore.Packet

  @adv_type_chat 1
  @adv_flag_name 0x80
  @max_name 31

  def build_flood(seed, pub, name, timestamp \\ nil)
      when byte_size(seed) == 32 and byte_size(pub) == 32 and is_binary(name) do
    ts = timestamp || System.system_time(:second)
    app = app_data(name)
    payload = encode_payload(pub, ts, seed, app)

    Packet.build(Packet.route_flood(), Packet.type_advert(), 0, <<>>, payload)
    |> Packet.encode()
  end

  def encode_payload(pub, timestamp, seed, app_data)
      when byte_size(pub) == 32 and is_integer(timestamp) and is_binary(app_data) do
    msg = pub <> <<timestamp::little-32>> <> app_data
    sig = Crypto.sign(seed, msg)
    pub <> <<timestamp::little-32>> <> sig <> app_data
  end

  def app_data(name) when is_binary(name) do
    trimmed =
      name |> String.slice(0, @max_name) |> :erlang.binary_to_list() |> :erlang.list_to_binary()

    <<Bitwise.bor(@adv_type_chat, @adv_flag_name), trimmed::binary>>
  end

  def parse_payload(<<pub::binary-32, ts::little-32, sig::binary-64, app::binary>> = _payload) do
    msg = pub <> <<ts::little-32>> <> app

    if Crypto.verify(pub, msg, sig) do
      {:ok, %{public_key: pub, timestamp: ts, app_data: app, name: parse_name(app)}}
    else
      {:error, :bad_signature}
    end
  end

  def parse_payload(_), do: {:error, :invalid_advert}

  defp parse_name(<<flags, rest::binary>>) do
    if Bitwise.band(flags, @adv_flag_name) != 0 do
      rest |> String.trim_trailing(<<0>>) |> String.trim()
    else
      nil
    end
  end

  defp parse_name(_), do: nil
end
