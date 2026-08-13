defmodule Isthmus.Policy do
  @moduledoc "Persisted policy knobs (registration open, budgets, directions, …)."

  import Ecto.Query
  alias Isthmus.Repo
  alias Isthmus.Policy.Setting

  @defaults %{
    "registration_open" => true,
    "announce_min_interval_sec" => 3600,
    "nostr_publish_budget_per_hour" => 60,
    # Empty list = all directions allowed. Otherwise "from>to" strings.
    "gateway_allow_directions" => [],
    "gateway_deny_directions" => [],
    # Drop MeshCore default Public (GRP_TXT/GRP_DATA) on tunnels unless opted in.
    "tunnel_block_meshcore_public" => true
  }

  @type key :: String.t()
  @type value :: term()
  @type direction :: :ok | {:drop, :direction_denied | :direction_not_allowed}

  @doc "When true (default), tunnels do not carry MeshCore default Public channel traffic."
  @spec tunnel_block_meshcore_public?() :: boolean()
  def tunnel_block_meshcore_public?, do: get("tunnel_block_meshcore_public") != false

  @spec get(key()) :: value()
  def get(key) when is_binary(key) do
    case Repo.get_by(Setting, key: key) do
      nil -> Map.get(@defaults, key)
      %Setting{value: %{"v" => v}} -> v
      %Setting{value: value} -> value
    end
  end

  @spec registration_open?() :: boolean()
  def registration_open?, do: get("registration_open") == true

  @spec put(key(), value()) :: {:ok, Setting.t()} | {:error, Ecto.Changeset.t()}
  def put(key, value) when is_binary(key) do
    case Repo.get_by(Setting, key: key) do
      nil ->
        %Setting{}
        |> Setting.changeset(%{key: key, value: %{"v" => value}})
        |> Repo.insert()

      setting ->
        setting
        |> Setting.changeset(%{value: %{"v" => value}})
        |> Repo.update()
    end
  end

  @spec all_settings() :: %{String.t() => value()}
  def all_settings do
    db =
      Repo.all(from s in Setting, select: {s.key, s.value})
      |> Map.new(fn
        {k, %{"v" => v}} -> {k, v}
        {k, v} -> {k, v}
      end)

    Map.merge(@defaults, db)
  end

  @doc """
  Returns `:ok` or `{:drop, reason}` for a gateway direction.

  Direction key is `"from>to"` (e.g. `"nostr>reticulum"`).
  """
  @spec allow_gateway_direction?(term(), term()) :: direction()
  def allow_gateway_direction?(from_network, to_network) do
    from = to_string(from_network)
    to = to_string(to_network)
    key = "#{from}>#{to}"

    deny = List.wrap(get("gateway_deny_directions"))
    allow = List.wrap(get("gateway_allow_directions"))

    cond do
      key in deny -> {:drop, :direction_denied}
      allow == [] -> :ok
      key in allow -> :ok
      true -> {:drop, :direction_not_allowed}
    end
  end

  @spec direction_keys() :: [String.t()]
  def direction_keys do
    nets = ~w(nostr reticulum meshcore meshtastic agent)

    for from <- nets, to <- nets, from != to do
      "#{from}>#{to}"
    end
  end
end
