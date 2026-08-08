defmodule Isthmus.NetworkAdapter do
  @moduledoc """
  Behaviour for pluggable network adapters (Reticulum, MeshCore, Nostr, …).
  """

  @type network_id :: :reticulum | :meshcore | :nostr | atom()
  @type identity_ref :: String.t()
  @type presentation :: %{
          required(:format_id) => String.t(),
          required(:label) => String.t(),
          required(:uri_or_text) => String.t(),
          required(:qr_payload) => String.t() | nil,
          required(:app_hints) => [String.t()]
        }

  @callback network_id() :: network_id()
  @callback capabilities() :: MapSet.t(atom()) | [atom()]
  @callback parse_identity_ref(String.t()) :: {:ok, identity_ref(), map()} | {:error, term()}
  @callback generate_proxy_identity(map()) ::
              {:ok,
               %{
                 identity_ref: identity_ref(),
                 public_material: map(),
                 private_material: map(),
                 presentations: [presentation()]
               }}
              | {:error, term()}
  @callback identity_presentations(identity_ref(), map()) :: [presentation()]
  @callback health() :: map()

  @optional_callbacks [
    send_message: 3,
    subscribe_inbound: 1,
    mtu: 1,
    send_raw: 2,
    inject_raw: 2,
    subscribe_raw: 1,
    estimated_bitrate: 1,
    announce_or_advert: 2
  ]

  @callback send_message(identity_ref(), String.t(), map()) ::
              :ok | {:ok, term()} | {:error, term()}
  @callback subscribe_inbound(pid()) :: :ok | {:error, term()}
  @callback mtu(map()) :: pos_integer()
  @callback send_raw(binary(), map()) :: :ok | {:error, term()}

  @doc """
  Emit a tunnel-delivered packet onto this network's local segment.

  Distinct from `c:send_raw/2`, which originates traffic from our own identity.
  A network that can act as a tunnel *payload* implements this to replay a
  foreign packet verbatim, so the far island sees it unchanged. Adapters
  without a transparent injection path simply omit it and `send_raw/2` is used.
  """
  @callback inject_raw(binary(), map()) :: :ok | {:error, term()}
  @callback subscribe_raw(pid()) :: :ok | {:error, term()}
  @callback estimated_bitrate(map()) :: non_neg_integer()
  @callback announce_or_advert(identity_ref(), map()) :: :ok | {:error, term()}
end
