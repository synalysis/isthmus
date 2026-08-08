defmodule Isthmus.Networks.LocalIdentity do
  @moduledoc """
  This node's own identity on each network, in the form a remote operator would
  paste as their `Isthmus.Tunnel.Peer` `peer_ref`.

  `peer_ref` names the *remote* endpoint on the carrier network, so setting up a
  tunnel means each side hands the other its own ref. What that ref is differs
  per network, and not every network can answer:

    * `nostr` — the service pubkey tunnel events are signed with (exact)
    * `meshcore` — the companion radio's own public key, learned on connect
    * `reticulum` — no node-level identity exists; the closest thing is the set
      of LXMF destinations we announce (see `t:status/0` `:partial`)
    * `meshtastic` — the transport is an in-memory stub with no radio identity
  """

  alias Isthmus.Networks.{MeshCore, Reticulum}
  alias Isthmus.Nostr.Crypto

  @type status :: :ok | :partial | :pending | :unavailable

  @type t :: %{
          network: String.t(),
          status: status(),
          refs: [String.t()],
          note: String.t() | nil,
          hint: String.t() | nil
        }

  @doc "Own identity on `network` (string or atom)."
  @spec for_network(String.t() | atom()) :: t()
  def for_network(network) when is_atom(network), do: for_network(Atom.to_string(network))

  def for_network("nostr") do
    case Crypto.service_pubkey_hex() do
      nil ->
        unavailable("nostr", "No Nostr service identity configured.",
          hint: "Set ISTHMUS_NOSTR_NSEC and restart."
        )

      hex ->
        %{
          network: "nostr",
          status: :ok,
          refs: [hex],
          note: "Service pubkey that signs outbound tunnel events.",
          hint: nil
        }
    end
  end

  def for_network("meshcore") do
    case meshcore_self_ref() do
      nil ->
        %{
          network: "meshcore",
          status: :pending,
          refs: [],
          note: "The companion reports its own key when it connects.",
          hint: "Connect the MeshCore companion, then reload."
        }

      ref ->
        %{
          network: "meshcore",
          status: :ok,
          refs: [ref],
          note: "Public key of the attached companion radio.",
          hint: nil
        }
    end
  end

  def for_network("reticulum") do
    case reticulum_tunnel_ref() do
      ref when is_binary(ref) ->
        %{
          network: "reticulum",
          status: :ok,
          refs: [ref],
          note:
            "This node's isthmus.tunnel destination. Paste it as the peer ref on the " <>
              "remote side to pair a point-to-point (addressed) tunnel.",
          hint: nil
        }

      _ ->
        reticulum_broadcast_identity()
    end
  end

  def for_network("meshtastic") do
    unavailable("meshtastic", "The Meshtastic transport is an in-memory stub.",
      hint: "No radio client is bound yet, so there is no node id to share."
    )
  end

  def for_network(other) when is_binary(other) do
    unavailable(other, "Unknown network.")
  end

  defp unavailable(network, note, opts \\ []) do
    %{
      network: network,
      status: :unavailable,
      refs: [],
      note: note,
      hint: Keyword.get(opts, :hint)
    }
  end

  defp meshcore_self_ref do
    case safe(fn -> MeshCore.health() end) do
      %{self_ref: ref} when is_binary(ref) and ref != "" -> ref
      _ -> nil
    end
  end

  defp reticulum_broadcast_identity do
    case reticulum_destinations() do
      [] ->
        unavailable("reticulum", "No tunnel destination yet.",
          hint: "Wait for the RNS sidecar to come up, or announce a group first."
        )

      refs ->
        %{
          network: "reticulum",
          status: :partial,
          refs: refs,
          note:
            "Broadcast mode (ISTHMUS_TUNNEL_ADDRESSED=0): tunnel frames aren't " <>
              "addressed. These are the announced LXMF destinations, useful only so " <>
              "the remote can link announce sightings to the tunnel.",
          hint: nil
        }
    end
  end

  defp reticulum_destinations do
    case safe(fn -> Reticulum.instance_status() end) do
      {:ok, %{registered: registered}} when is_list(registered) ->
        registered |> Enum.filter(&is_binary/1) |> Enum.uniq()

      _ ->
        []
    end
  end

  defp reticulum_tunnel_ref do
    case safe(fn -> Reticulum.tunnel_destination_hash() end) do
      hash when is_binary(hash) and hash != "" -> hash
      _ -> nil
    end
  end

  defp safe(fun) do
    fun.()
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end
end
