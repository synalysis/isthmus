defmodule Isthmus.Nostr.Crypto do
  @moduledoc """
  DM crypto helpers via `nostr_lib`.

  Prefer per-group vaulted Nostr proxies (`nostr`/`proxy` legs) for group DM
  encrypt/decrypt and routing. `ISTHMUS_NOSTR_NSEC` is this node’s **service**
  identity for the Nostr tunnel carrier. Inbound DMs to that key are retained in
  `Networks.Nostr.ServiceInbox` only — they are not matched to groups and are not
  used as a chat sender.

  Outbound DMs prefer **NIP-17** (gift-wrapped). Inbound accepts NIP-17 kind 1059
  and legacy **NIP-04** kind 4 for older clients.

  Optional NIP-17 `subject` tags (`isthmus/<slug>`) can hint a group room when
  the recipient is a per-group proxy — see [NIP-17](https://nips.nostr.com/17).

  Seckeys are BIP340-normalized (even-Y) before use — required for ECDH agreement
  when peers lift x-only keys with the `0x02` prefix.
  """

  alias Isthmus.Nostr.Bech32
  alias Isthmus.Nostr.Event

  # secp256k1 curve order
  @n 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141

  def service_keypair do
    case System.get_env("ISTHMUS_NOSTR_NSEC") do
      nil ->
        :none

      nsec ->
        case Bech32.decode(String.trim(nsec)) do
          {:ok, "nsec", seckey} when byte_size(seckey) == 32 ->
            seckey = normalize_seckey(seckey)
            pubkey = Secp256k1.pubkey(seckey, :xonly)
            {:ok, seckey, pubkey}

          _ ->
            :invalid
        end
    end
  end

  def service_pubkey_hex do
    case service_keypair() do
      {:ok, _sk, pk} -> Base.encode16(pk, case: :lower)
      _ -> nil
    end
  end

  @doc """
  BIP340-normalize a seckey so its public key has even Y (compressed prefix `0x02`).
  """
  def normalize_seckey(seckey) when byte_size(seckey) == 32 do
    case Secp256k1.pubkey(seckey, :compressed) do
      <<0x02, _::binary-32>> ->
        seckey

      <<0x03, _::binary-32>> ->
        encode_uint256(@n - :binary.decode_unsigned(seckey))
    end
  end

  def normalize_seckey_hex(seckey_hex) when is_binary(seckey_hex) do
    seckey_hex
    |> Base.decode16!(case: :lower)
    |> normalize_seckey()
    |> Base.encode16(case: :lower)
  end

  @doc "NIP-04 conversation encrypt (legacy). Keys may be binary or hex."
  def nip04_encrypt(seckey, peer_pubkey, plaintext) do
    Nostr.Crypto.encrypt(plaintext, seckey_hex(seckey), pubkey_hex(peer_pubkey))
  end

  @doc "NIP-04 conversation decrypt (legacy)."
  def nip04_decrypt(seckey, peer_pubkey, content) do
    try do
      {:ok, Nostr.Crypto.decrypt(content, seckey_hex(seckey), pubkey_hex(peer_pubkey))}
    rescue
      _ -> {:error, :decrypt_failed}
    end
  end

  @doc "NIP-44 v2 conversation encrypt. Keys may be binary or hex."
  def nip44_encrypt(seckey, peer_pubkey, plaintext) when is_binary(plaintext) do
    Nostr.NIP44.encrypt(plaintext, seckey_hex(seckey), pubkey_hex(peer_pubkey))
  end

  @doc "NIP-44 v2 conversation decrypt. Keys may be binary or hex."
  def nip44_decrypt(seckey, peer_pubkey, content) when is_binary(content) do
    Nostr.NIP44.decrypt(content, seckey_hex(seckey), pubkey_hex(peer_pubkey))
  end

  @doc """
  Build outbound DM event map(s) for relay publish.

  Returns `{:ok, [wire_map]}` — NIP-17 gift wraps addressed to the recipient.

  Options:
  - `:subject` — NIP-17 room subject (used to route replies to a registration group)

  When `:subject` is set, the sender's own gift-wrap copy is unwrapped to confirm
  the subject survived sealing (NIP-17 room routing depends on it).
  """
  def dm_events(seckey, recipient_pubkey_hex, plaintext, opts \\ []) do
    seckey_hex = seckey_hex(seckey)
    recipient = pubkey_hex(recipient_pubkey_hex)
    nip_opts = Keyword.take(opts, [:subject, :reply_to, :created_at, :quotes])
    expected_subject = Keyword.get(nip_opts, :subject)

    {:ok, wraps} = Nostr.NIP17.send_dm(seckey_hex, [recipient], plaintext, nip_opts)

    with :ok <- verify_subject_in_wraps(wraps, seckey_hex, expected_subject) do
      maps =
        wraps
        |> Enum.filter(&(&1.recipient == recipient))
        |> Enum.map(&Event.to_wire_map(&1.event))

      {:ok, maps}
    end
  end

  @doc "Legacy NIP-04 kind-4 event (wire map). Prefer `dm_events/3`."
  def dm_event(seckey, recipient_pubkey_hex, plaintext) do
    seckey_hex = seckey_hex(seckey)
    recipient = pubkey_hex(recipient_pubkey_hex)

    dm = Nostr.Event.DirectMessage.create(plaintext, seckey_hex, recipient)
    Event.to_wire_map(dm.event)
  end

  @doc """
  Try to decrypt an inbound DM event map.

  Supports kind 1059 (NIP-17) and kind 4 (NIP-04).
  Returns `{:ok, plaintext, author_pubkey_hex, meta}` where meta includes
  `:subject` when present on the NIP-17 rumor (chat room topic).

  Tolerates a `nostr_lib` quirk where `Seal.unwrap/2` can return
  `{:ok, {:error, :invalid_id, rumor}}` for client-built rumors whose `id`
  does not match NIP-01 serialization — content is still usable after
  recomputing the id.
  """
  def decrypt_inbound(seckey, event) when is_map(event) do
    seckey_hex = seckey_hex(seckey)
    kind = event["kind"] || event[:kind]

    case kind do
      1059 ->
        decrypt_nip17(seckey_hex, event)

      4 ->
        author = pubkey_hex(event["pubkey"] || "")

        case nip04_decrypt(seckey, author, event["content"] || "") do
          {:ok, text} -> {:ok, text, author, %{}}
          error -> error
        end

      14 ->
        subject = subject_from_tags(event["tags"] || event[:tags] || [])
        meta = if subject, do: %{subject: subject}, else: %{}
        {:ok, event["content"] || "", pubkey_hex(event["pubkey"] || ""), meta}

      _ ->
        {:error, :unsupported_kind}
    end
  end

  defp decrypt_nip17(seckey_hex, event) do
    case Nostr.Event.parse(event) do
      %Nostr.Event{} = parsed ->
        case receive_dm_safe(parsed, seckey_hex) do
          {:ok, message, sender} ->
            meta =
              case subject_from_message(message) do
                nil -> %{}
                subject -> %{subject: subject}
              end

            {:ok, message.content, sender, meta}

          {:error, _} = err ->
            err
        end

      _ ->
        {:error, :invalid_event}
    end
  end

  defp receive_dm_safe(parsed, seckey_hex) do
    try do
      case Nostr.NIP17.receive_dm(parsed, seckey_hex) do
        {:ok, message, sender} ->
          {:ok, message, sender}

        {:error, reason} ->
          case receive_dm_lenient(parsed, seckey_hex) do
            {:ok, _, _} = ok -> ok
            {:error, _} -> {:error, reason}
          end

        _other ->
          receive_dm_lenient(parsed, seckey_hex)
      end
    rescue
      _e ->
        # nostr_lib crashes (BadMapError) when Seal.unwrap nests {:error, :invalid_id, rumor}.
        receive_dm_lenient(parsed, seckey_hex)
    end
  end

  # Bypass nostr_lib's validate_sender BadMapError when Seal.unwrap nests
  # `{:error, :invalid_id, rumor}` inside `{:ok, ...}`.
  defp receive_dm_lenient(%Nostr.Event{} = event, seckey_hex) do
    alias Nostr.Event.{GiftWrap, PrivateMessage, Rumor, Seal}

    with %GiftWrap{} = gift_wrap <- GiftWrap.parse(event),
         {:ok, seal} <- GiftWrap.unwrap(gift_wrap, seckey_hex),
         {:ok, rumor_result} <- Seal.unwrap(seal, seckey_hex),
         {:ok, rumor} <- normalize_rumor(rumor_result),
         :ok <- validate_rumor_sender(rumor, seal),
         %Rumor{kind: 14} <- rumor do
      {:ok, PrivateMessage.parse(rumor), seal.sender}
    else
      %Rumor{kind: kind} ->
        {:error, {:unexpected_kind, kind}}

      {:error, _} = err ->
        err

      other ->
        {:error, {:nip17_lenient_failed, other}}
    end
  end

  defp normalize_rumor(%Nostr.Event.Rumor{} = rumor), do: {:ok, rumor}

  defp normalize_rumor({:error, :invalid_id, %Nostr.Event.Rumor{} = rumor}) do
    # Client rumor id ≠ NIP-01 hash; content still decrypted. Prefer recomputed id.
    {:ok, %{rumor | id: Nostr.Event.Rumor.compute_id(rumor)}}
  end

  defp normalize_rumor(other), do: {:error, {:invalid_rumor, other}}

  defp validate_rumor_sender(%{pubkey: pubkey}, %{sender: sender})
       when is_binary(pubkey) and pubkey == sender,
       do: :ok

  defp validate_rumor_sender(_, _), do: {:error, :sender_mismatch}

  # Confirm subject is present on the sealed rumor via the sender's gift-wrap copy.
  defp verify_subject_in_wraps(_wraps, _seckey_hex, subject)
       when not is_binary(subject) or subject == "",
       do: :ok

  defp verify_subject_in_wraps(wraps, seckey_hex, expected) when is_list(wraps) do
    sender_pubkey = Nostr.Crypto.pubkey(seckey_hex)

    case Enum.find(wraps, &(&1.recipient == sender_pubkey)) do
      %{event: event} ->
        case Nostr.NIP17.receive_dm(event, seckey_hex) do
          {:ok, message, _} ->
            case subject_from_message(message) do
              ^expected ->
                :ok

              other ->
                {:error, {:subject_not_preserved, expected: expected, got: other}}
            end

          {:error, reason} ->
            {:error, {:subject_verify_failed, reason}}
        end

      nil ->
        {:error, :subject_verify_missing_sender_wrap}
    end
  end

  defp subject_from_message(%{subject: subject})
       when is_binary(subject) and subject != "",
       do: subject

  defp subject_from_message(%{rumor: %{tags: tags}}) when is_list(tags) do
    subject_from_tags(tags)
  end

  defp subject_from_message(_), do: nil

  defp subject_from_tags(tags) when is_list(tags) do
    Enum.find_value(tags, fn
      %{type: :subject, data: subject} when is_binary(subject) and subject != "" ->
        subject

      %{"type" => "subject", "data" => subject} when is_binary(subject) and subject != "" ->
        subject

      ["subject", subject | _] when is_binary(subject) and subject != "" ->
        subject

      _ ->
        nil
    end)
  end

  defp subject_from_tags(_), do: nil

  defp seckey_hex(bin) when byte_size(bin) == 32 do
    bin |> normalize_seckey() |> Base.encode16(case: :lower)
  end

  defp seckey_hex(hex) when is_binary(hex) and byte_size(hex) == 64 do
    normalize_seckey_hex(String.downcase(hex))
  end

  defp pubkey_hex(bin) when byte_size(bin) == 32, do: Base.encode16(bin, case: :lower)
  defp pubkey_hex(hex) when is_binary(hex), do: String.downcase(hex)

  defp encode_uint256(int) when is_integer(int) and int >= 0 do
    bin = :binary.encode_unsigned(int, :big)
    pad = 32 - byte_size(bin)
    :binary.copy(<<0>>, pad) <> bin
  end
end
