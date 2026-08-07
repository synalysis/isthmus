defmodule Isthmus.Auth do
  @moduledoc """
  NIP-07 challenge/response authentication with kind/tag/freshness checks.
  """

  alias Isthmus.Auth.Store
  alias Isthmus.Nostr.Bech32
  alias Isthmus.Nostr.Event

  @challenge_ttl_sec 120
  @login_token_ttl_sec 60
  @max_created_at_skew_sec 120
  @login_kind 27_235

  def create_challenge(origin \\ "isthmus") do
    nonce = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    expires_at = System.system_time(:second) + @challenge_ttl_sec

    challenge = %{
      nonce: nonce,
      origin: origin,
      expires_at: expires_at,
      message: "Isthmus login:#{origin}:#{nonce}:#{expires_at}"
    }

    :ets.insert(Store.table(), {{:challenge, nonce}, challenge})
    challenge
  end

  def verify_signed_event(event) when is_map(event) do
    with {:ok, pubkey} <- Event.verify(event),
         :ok <- validate_login_event(event),
         content when is_binary(content) <- Map.get(event, "content"),
         {:ok, challenge} <- parse_challenge_content(content),
         true <- challenge.expires_at >= System.system_time(:second),
         true <- match_stored_challenge?(challenge),
         :ok <- consume_challenge(challenge.nonce) do
      npub =
        case Base.decode16(pubkey, case: :lower) do
          {:ok, bin} -> Bech32.encode_npub(bin)
          _ -> pubkey
        end

      token = mint_login_token(pubkey, npub)
      {:ok, %{pubkey_hex: pubkey, npub: npub, token: token}}
    else
      false -> {:error, :challenge_invalid}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :auth_failed}
    end
  end

  def consume_login_token(token) when is_binary(token) do
    case :ets.take(Store.table(), {:login, token}) do
      [{{:login, ^token}, %{expires_at: exp} = session}] ->
        if exp >= System.system_time(:second) do
          {:ok, Map.take(session, [:pubkey_hex, :npub])}
        else
          {:error, :token_expired}
        end

      _ ->
        {:error, :token_invalid}
    end
  end

  defp validate_login_event(event) do
    kind = event["kind"] || event[:kind]
    created_at = event["created_at"] || event[:created_at]
    tags = event["tags"] || event[:tags] || []
    now = System.system_time(:second)

    cond do
      kind != @login_kind ->
        {:error, :invalid_kind}

      not is_integer(created_at) ->
        {:error, :invalid_created_at}

      abs(now - created_at) > @max_created_at_skew_sec ->
        {:error, :stale_event}

      not has_tag?(tags, "method", "LOGIN") ->
        {:error, :missing_method_tag}

      true ->
        :ok
    end
  end

  defp has_tag?(tags, name, value) do
    Enum.any?(tags, fn
      [^name, ^value | _] -> true
      _ -> false
    end)
  end

  defp mint_login_token(pubkey, npub) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

    :ets.insert(
      Store.table(),
      {{:login, token},
       %{
         pubkey_hex: pubkey,
         npub: npub,
         expires_at: System.system_time(:second) + @login_token_ttl_sec
       }}
    )

    token
  end

  defp parse_challenge_content(content) do
    case String.split(content, ":") do
      ["Isthmus login", origin, nonce, expires] ->
        {:ok,
         %{
           origin: origin,
           nonce: nonce,
           expires_at: String.to_integer(expires),
           message: content
         }}

      _ ->
        {:error, :bad_challenge_format}
    end
  end

  defp match_stored_challenge?(%{nonce: nonce, message: message, expires_at: expires_at}) do
    case :ets.lookup(Store.table(), {:challenge, nonce}) do
      [{{:challenge, ^nonce}, stored}] ->
        stored.message == message and stored.expires_at == expires_at

      _ ->
        false
    end
  end

  defp consume_challenge(nonce) do
    case :ets.take(Store.table(), {:challenge, nonce}) do
      [_] -> :ok
      _ -> {:error, :challenge_missing}
    end
  end
end
