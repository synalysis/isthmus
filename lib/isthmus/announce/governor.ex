defmodule Isthmus.Announce.Governor do
  @moduledoc """
  Rate/dedup authority for announces, adverts, tunnel control, and Nostr publishes.

  `tunnel_data` is budget-only: packet/outbox dedup already collapses repeats in
  `Tunnel.Bridge` / `Tunnel.Outbox`. A per-tunnel TTL would block distinct chat
  messages after an advert (or any prior DATA) for the whole window.
  """
  use GenServer

  alias Isthmus.Announce.Dedup
  alias Isthmus.Policy
  alias Isthmus.Repo

  defmodule Event do
    use Ecto.Schema
    import Ecto.Changeset

    @primary_key {:id, :binary_id, autogenerate: true}
    schema "governor_events" do
      field :network, :string
      field :class, :string
      field :identity_key, :string
      field :action, :string
      field :reason, :string
      field :seen_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    def changeset(e, attrs) do
      e
      |> cast(attrs, [:network, :class, :identity_key, :action, :reason, :seen_at])
      |> validate_required([:network, :class, :identity_key, :action, :seen_at])
    end
  end

  # Classes listed here use identity-key TTL dedup. `tunnel_data` is intentionally
  # absent — only the per-network hourly budget applies.
  @ttl %{
    "announce" => 3_600,
    "advert" => 21_600,
    "tunnel_control" => 5,
    "nostr_metadata" => 86_400,
    "gateway_message" => 10
  }

  @budget_only_classes MapSet.new(["tunnel_data"])

  @budgets %{
    # tokens per hour
    "reticulum" => 120,
    "meshcore" => 60,
    "nostr" => 60
  }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns `:ok` or `{:drop, reason}`.
  """
  def allow?(class, network, identity_key) do
    GenServer.call(
      __MODULE__,
      {:allow, to_string(class), to_string(network), to_string(identity_key)}
    )
  end

  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  def drops_by_reason(limit \\ 50) do
    import Ecto.Query

    Event
    |> where([e], e.action == "drop")
    |> order_by([e], desc: e.seen_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Recent drops collapsed by network/class/reason/identity.

  Each row includes `count` and `seen_at` (most recent occurrence) so the admin
  UI can show how stale a repeated dedup storm is.
  """
  def drops_summary(limit \\ 20) do
    import Ecto.Query

    # Pull a wider window, then collapse — identical advert/tunnel dedups
    # otherwise drown the list.
    sample = max(limit * 10, 100)

    Event
    |> where([e], e.action == "drop")
    |> order_by([e], desc: e.seen_at)
    |> limit(^sample)
    |> Repo.all()
    |> Enum.group_by(&{&1.network, &1.class, &1.reason, &1.identity_key})
    |> Enum.map(fn {{network, class, reason, identity_key}, events} ->
      latest = Enum.max_by(events, & &1.seen_at, DateTime)

      %{
        network: network,
        class: class,
        reason: reason,
        identity_key: identity_key,
        count: length(events),
        seen_at: latest.seen_at
      }
    end)
    |> Enum.sort_by(& &1.seen_at, {:desc, DateTime})
    |> Enum.take(limit)
  end

  @impl true
  def init(_opts) do
    {:ok, %{tokens: %{}, hour_bucket: current_hour(), allowed: 0, dropped: 0}}
  end

  @impl true
  def handle_call({:allow, class, network, identity_key}, _from, state) do
    state = maybe_rotate_hour(state)

    {result, state} =
      cond do
        identity_dedup?(class) and
            Dedup.seen?(dedup_key(network, class, identity_key), ttl_for(class)) ->
          record_drop(network, class, identity_key, "dedup")
          {{:drop, :dedup}, update_in(state.dropped, &(&1 + 1))}

        not tokens_available?(state, network) ->
          record_drop(network, class, identity_key, "budget")
          {{:drop, :budget}, update_in(state.dropped, &(&1 + 1))}

        true ->
          record_allow(network, class, identity_key)
          state = consume_token(state, network)
          {:ok, update_in(state.allowed, &(&1 + 1))}
      end

    {:reply, result, state}
  end

  def handle_call(:stats, _from, state) do
    {:reply,
     %{
       allowed: state.allowed,
       dropped: state.dropped,
       tokens: state.tokens,
       hour_bucket: state.hour_bucket,
       policy_nostr_budget: Policy.get("nostr_publish_budget_per_hour")
     }, state}
  end

  defp identity_dedup?(class), do: not MapSet.member?(@budget_only_classes, class)

  defp dedup_key(network, class, identity_key), do: "#{network}|#{class}|#{identity_key}"

  defp ttl_for(class), do: Map.get(@ttl, class, 60)

  defp tokens_available?(state, network) do
    budget = budget_for(network)
    used = Map.get(state.tokens, network, 0)
    used < budget
  end

  defp consume_token(state, network) do
    update_in(state, [:tokens, network], fn
      nil -> 1
      n -> n + 1
    end)
  end

  defp budget_for(network) do
    case network do
      "nostr" -> Policy.get("nostr_publish_budget_per_hour") || @budgets["nostr"]
      other -> Map.get(@budgets, other, 60)
    end
  end

  defp maybe_rotate_hour(%{hour_bucket: bucket} = state) do
    hour = current_hour()

    if hour != bucket do
      %{state | hour_bucket: hour, tokens: %{}}
    else
      state
    end
  end

  defp current_hour do
    now = DateTime.utc_now()
    "#{now.year}-#{now.month}-#{now.day}T#{now.hour}"
  end

  defp record_allow(network, class, identity_key) do
    insert_event(network, class, identity_key, "allow", nil)
  end

  defp record_drop(network, class, identity_key, reason) do
    insert_event(network, class, identity_key, "drop", reason)
  end

  defp insert_event(network, class, identity_key, action, reason) do
    %Event{}
    |> Event.changeset(%{
      network: network,
      class: class,
      identity_key: identity_key,
      action: action,
      reason: reason,
      seen_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
    |> Repo.insert()
  rescue
    _ -> :ok
  end
end
