defmodule Isthmus.Networks do
  @moduledoc "Adapter registry."

  alias Isthmus.Networks.{MeshCore, Meshtastic, Nostr, Reticulum}

  @adapters %{
    nostr: Nostr,
    reticulum: Reticulum,
    meshcore: MeshCore,
    meshtastic: Meshtastic
  }

  def adapter!(network) when is_atom(network), do: Map.fetch!(@adapters, network)
  def adapter!(network) when is_binary(network), do: adapter!(String.to_existing_atom(network))

  def list_adapters, do: Map.keys(@adapters)

  def health_all do
    Map.new(@adapters, fn {id, mod} -> {id, mod.health()} end)
  end

  @doc "True when the adapter implements announce/advert discovery."
  def supports_announce?(network) do
    mod = adapter!(network)
    caps = mod.capabilities()

    cond do
      function_exported?(mod, :announce_or_advert, 2) == false ->
        false

      is_struct(caps, MapSet) ->
        MapSet.member?(caps, :announce)

      is_list(caps) ->
        :announce in caps

      true ->
        false
    end
  rescue
    _ -> false
  end

  @doc """
  Send an announce/advert for `identity_ref` on `network`.

  Options:
  - `:force` — skip announce governor dedup/budget (for explicit UI actions)
  - `:flood` — MeshCore flood advert (default zero-hop)
  """
  def announce(network, identity_ref, opts \\ %{}) when is_binary(identity_ref) do
    unless supports_announce?(network) do
      {:error, :announce_not_supported}
    else
      mod = adapter!(network)
      opts = Map.new(opts)

      case mod.announce_or_advert(identity_ref, opts) do
        :ok -> :ok
        {:ok, _} -> :ok
        {:error, _} = err -> err
      end
    end
  end
end
