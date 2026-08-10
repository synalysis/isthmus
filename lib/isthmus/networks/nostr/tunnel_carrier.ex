defmodule Isthmus.Networks.Nostr.TunnelCarrier do
  @moduledoc """
  Opaque tunnel frames over Nostr (RNS-over-Nostr / MeshCore-over-Nostr carrier).

  Uses ephemeral kind `21278` with tag `t=isthmus-tunnel`. When a peer pubkey is
  known, content is NIP-44 encrypted under the service identity (inner payload is
  base64 of the ISTH frame). Inbound still accepts legacy `encryption=nip04` and
  plaintext base64 for older peers.
  """

  require Logger

  alias Isthmus.Nostr.Crypto
  alias Isthmus.Nostr.Event
  alias Isthmus.Networks.Nostr.RelayPool
  alias Isthmus.Tunnel.Engine

  @kind 21_278
  @tag "isthmus-tunnel"
  @enc_nip44 "nip44"
  @enc_nip04 "nip04"

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
    case peer_pubkey_hex(peer) do
      {:ok, hex} ->
        # Base64 the binary ISTH frame so the NIP-44 plaintext is always UTF-8 safe.
        b64 = Base.encode64(payload)
        ciphertext = Crypto.nip44_encrypt(seckey, hex, b64)

        {ciphertext,
         [
           ["t", @tag],
           ["p", hex],
           ["encryption", @enc_nip44]
         ]}

      :error ->
        # Fall back to unencrypted so the frame still ships; peer_ref should have
        # been normalized on save.
        {Base.encode64(payload), [["t", @tag]]}
    end
  end

  defp encode_content(_seckey, _peer, payload) do
    {Base.encode64(payload), [["t", @tag]]}
  end

  defp decode_content(event) do
    content = event["content"] || ""
    tags = event["tags"] || []

    case encryption_scheme(tags) do
      :nip44 -> decrypt_inner(content, event, :nip44)
      :nip04 -> decrypt_inner(content, event, :nip04)
      :none -> Base.decode64(content)
    end
  end

  defp encryption_scheme(tags) when is_list(tags) do
    Enum.find_value(tags, :none, fn
      ["encryption", @enc_nip44 | _] -> :nip44
      ["encryption", @enc_nip04 | _] -> :nip04
      _ -> nil
    end)
  end

  defp encryption_scheme(_), do: :none

  defp decrypt_inner(content, event, scheme) do
    case Crypto.service_keypair() do
      {:ok, seckey, _} ->
        author = event["pubkey"]

        result =
          case scheme do
            :nip44 -> Crypto.nip44_decrypt(seckey, author, content)
            :nip04 -> Crypto.nip04_decrypt(seckey, author, content)
          end

        case result do
          {:ok, b64} -> Base.decode64(b64)
          other -> other
        end

      _ ->
        {:error, :no_service_nsec}
    end
  end

  defp tagged_tunnel?(event) do
    tags = event["tags"] || []

    Enum.any?(tags, fn
      ["t", @tag | _] -> true
      _ -> false
    end)
  end

  defp peer_pubkey_hex(peer) do
    case Isthmus.Networks.Nostr.parse_identity_ref(peer) do
      {:ok, hex, _} -> {:ok, hex}
      _ -> :error
    end
  end
end
