defmodule Isthmus.Gateway.Message do
  @moduledoc "Normalized cross-network message."

  @enforce_keys [:from_network, :body]
  defstruct [
    :from_network,
    :from_ref,
    :to_network,
    :to_ref,
    :body,
    :external_id,
    :group_id,
    meta: %{}
  ]

  @type network :: :nostr | :meshcore | :reticulum | :meshtastic | :agent | :admin
  @type t :: %__MODULE__{
          from_network: network() | String.t(),
          from_ref: String.t() | nil,
          to_network: network() | String.t() | nil,
          to_ref: String.t() | nil,
          body: String.t(),
          external_id: String.t() | nil,
          group_id: String.t() | nil,
          meta: map()
        }
end
