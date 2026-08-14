defmodule Isthmus.Registrations.Bind do
  @moduledoc """
  Proof-of-possession challenges for self-service MeshCore / Reticulum registration.

  The operator pastes an identity; Isthmus issues a nonce. Registration completes
  only when that identity sends a DM/LXMF containing `isthmus-bind:<nonce>`.
  """

  alias Isthmus.Auth.Store

  @ttl_sec 600
  @topic "registrations:bind"

  @type challenge :: %{
          nonce: String.t(),
          phrase: String.t(),
          network: String.t(),
          identity_ref: String.t(),
          owner_hex: String.t(),
          expires_at: integer()
        }

  @spec topic() :: String.t()
  def topic, do: @topic

  @spec start(String.t(), String.t(), String.t(), map()) :: {:ok, challenge()} | {:error, term()}
  def start(owner_hex, network, identity_ref, attrs) when is_binary(identity_ref) do
    nonce = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    expires_at = System.system_time(:second) + @ttl_sec

    challenge = %{
      nonce: nonce,
      phrase: phrase(nonce),
      network: to_string(network),
      identity_ref: String.downcase(identity_ref),
      owner_hex: String.downcase(owner_hex),
      attrs: Map.drop(attrs, [:bind_verified, "bind_verified"]),
      expires_at: expires_at
    }

    :ets.insert(Store.table(), {{:bind, challenge.network, challenge.identity_ref}, challenge})

    {:ok,
     Map.take(challenge, [:nonce, :phrase, :network, :identity_ref, :owner_hex, :expires_at])}
  end

  @spec complete(String.t(), String.t() | nil, String.t() | nil) ::
          {:ok, term()} | :error
  def complete(_network, from_ref, body) when not is_binary(from_ref) or not is_binary(body),
    do: :error

  def complete(network, from_ref, body) do
    network = to_string(network)
    ref = String.downcase(from_ref)

    case :ets.take(Store.table(), {:bind, network, ref}) do
      [{{:bind, ^network, ^ref}, challenge}] ->
        now = System.system_time(:second)

        cond do
          challenge.expires_at < now ->
            :error

          not contains_phrase?(body, challenge.phrase) ->
            :ets.insert(Store.table(), {{:bind, network, ref}, challenge})
            :error

          true ->
            finish(challenge)
        end

      _ ->
        :error
    end
  end

  @spec phrase(String.t()) :: String.t()
  def phrase(nonce) when is_binary(nonce), do: "isthmus-bind:#{nonce}"

  defp contains_phrase?(body, phrase) do
    String.contains?(String.downcase(body), String.downcase(phrase))
  end

  defp finish(challenge) do
    created_by =
      Map.get(challenge.attrs, :created_by) ||
        Map.get(challenge.attrs, "created_by") ||
        "self_service"

    attrs =
      challenge.attrs
      |> Map.put(:bind_verified, true)
      |> Map.put(:created_by, created_by)

    result =
      case challenge.network do
        "meshcore" ->
          Isthmus.Registrations.register_meshcore_primary(
            challenge.owner_hex,
            challenge.identity_ref,
            attrs
          )

        "reticulum" ->
          Isthmus.Registrations.register_reticulum_primary(
            challenge.owner_hex,
            challenge.identity_ref,
            attrs
          )

        _ ->
          {:error, :unsupported_network}
      end

    case result do
      {:ok, group} ->
        Phoenix.PubSub.broadcast(
          Isthmus.PubSub,
          @topic,
          {:bind_complete, challenge.owner_hex, group.id}
        )

        {:ok, group}

      other ->
        :ets.insert(
          Store.table(),
          {{:bind, challenge.network, challenge.identity_ref}, challenge}
        )

        other
    end
  end
end
