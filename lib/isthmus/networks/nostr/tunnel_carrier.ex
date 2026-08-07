defmodule Isthmus.Networks.Nostr.TunnelCarrier do
  @moduledoc """
  Opaque tunnel frames over Nostr (RNS-over-Nostr / MeshCore-over-Nostr carrier).

  Uses ephemeral kind `21278` with tag `t=isthmus-tunnel`. Content is base64 of
  the ISTH tunnel frame. When a peer pubkey is known, also tags `#p` and encrypts
  with NIP-04 under the service identity.
  """

  require Logger

  alias Isthmus.Nostr.Crypto
  alias Isthmus.Nostr.Event
  alias Isthmus.Networks.Nostr.RelayPool
  alias Isthmus.Tunnel.Engine

  @kind 21_278
  @tag "isthmus-tunnel"

  def kind, do: @kind
  def tag, do: @tag

  @doc "Publish an opaque tunnel payload via Nostr relays."
  def send_raw(payload, opts \\ %{}) when is_binary(payload) do
    case Crypto.service_keypair() do
      {:ok, seckey, _pubkey} ->
        peer = opts[:peer_ref] || opts["peer_ref"]
        {content, tags} = encode_content(seckey, peer, payload)
        seckey_hex = Base.encode16(seckey, case: :lower)

        nostr_tags =
          Enum.map(tags, fn list -> Nostr.Tag.parse(list) end)
          |> Enum.reject(&is_nil/1)

        event =
          @kind
          |> Nostr.Event.create(content: content, tags: nostr_tags)
          |> Nostr.Event.sign(seckey_hex)

        RelayPool.publish_event(Event.to_wire_map(event))

      :none ->
        {:error, :no_service_nsec}

      :invalid ->
        {:error, :invalid_service_nsec}
    end
  end

  @doc "Handle inbound Nostr event; if tunnel frame, feed Engine."
  def handle_inbound_event(event) when is_map(event) do
    kind = event["kind"] || event[:kind]

    if kind == @kind and tagged_tunnel?(event) do
      case decode_content(event) do
        {:ok, payload} when is_binary(payload) and byte_size(payload) > 0 ->
          Engine.handle_inbound_frame(payload)
          :ok

        {:error, reason} ->
          Logger.debug("nostr tunnel decode failed: #{inspect(reason)}")
          :error
      end
    else
      :ignore
    end
  end

  def filter_for_service(service_hex) when is_binary(service_hex) do
    %{"kinds" => [@kind], "#t" => [@tag], "#p" => [service_hex], "limit" => 50}
  end

  def filter_global do
    %{"kinds" => [@kind], "#t" => [@tag], "limit" => 50}
  end

  defp encode_content(seckey, peer, payload) when is_binary(peer) and peer != "" do
    b64 = Base.encode64(payload)
    ciphertext = Crypto.nip04_encrypt(seckey, peer, b64)
    {ciphertext, [["t", @tag], ["p", String.downcase(peer)], ["encryption", "nip04"]]}
  end

  defp encode_content(_seckey, _peer, payload) do
    {Base.encode64(payload), [["t", @tag]]}
  end

  defp decode_content(event) do
    content = event["content"] || ""
    tags = event["tags"] || []

    encrypted? =
      Enum.any?(tags, fn
        ["encryption", "nip04" | _] -> true
        _ -> false
      end)

    if encrypted? do
      case Crypto.service_keypair() do
        {:ok, seckey, _} ->
          author = event["pubkey"]

          case Crypto.nip04_decrypt(seckey, author, content) do
            {:ok, b64} -> Base.decode64(b64)
            other -> other
          end

        _ ->
          {:error, :no_service_nsec}
      end
    else
      Base.decode64(content)
    end
  end

  defp tagged_tunnel?(event) do
    tags = event["tags"] || []

    Enum.any?(tags, fn
      ["t", @tag | _] -> true
      _ -> false
    end)
  end
end
