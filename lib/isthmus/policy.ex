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
    "gateway_deny_directions" => []
  }

  def get(key) when is_binary(key) do
    case Repo.get_by(Setting, key: key) do
      nil -> Map.get(@defaults, key)
      %Setting{value: %{"v" => v}} -> v
      %Setting{value: value} -> value
    end
  end

  def registration_open?, do: get("registration_open") == true

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

  def direction_keys do
    nets = ~w(nostr reticulum meshcore)

    for from <- nets, to <- nets, from != to do
      "#{from}>#{to}"
    end
  end
end
