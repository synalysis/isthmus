defmodule Isthmus.Audit do
  @moduledoc "Cross-cutting audit event queries (governor + gateway + sightings)."

  import Ecto.Query
  alias Isthmus.Announce.Governor.Event, as: GovernorEvent
  alias Isthmus.Announce.Sighting
  alias Isthmus.Gateway.Activity
  alias Isthmus.Repo

  @kinds ~w(sighting governor gateway)

  @doc """
  Unified ops timeline entries for admin UI.

  Each entry: `%{at, kind, summary, detail, meta}`

  Options:
  - `:kinds` — list of `"sighting"` / `"governor"` / `"gateway"` (default: all)
  """
  def timeline(limit \\ 80, opts \\ [])

  def timeline(limit, opts) when is_integer(limit) and is_list(opts) do
    limit = max(limit, 1)
    kinds = normalize_kinds(Keyword.get(opts, :kinds, @kinds))

    if kinds == [] do
      []
    else
      each = if length(kinds) == 1, do: limit, else: max(div(limit, length(kinds)) + 5, 10)

      kinds
      |> Enum.flat_map(fn
        "governor" -> governor_entries(each)
        "gateway" -> gateway_entries(each)
        "sighting" -> sighting_entries(each)
        _ -> []
      end)
      |> Enum.sort_by(& &1.at, {:desc, DateTime})
      |> Enum.take(limit)
    end
  end

  def kinds, do: @kinds

  def governor_recent(limit \\ 50) do
    GovernorEvent
    |> order_by([e], desc: e.seen_at)
    |> limit(^limit)
    |> Repo.all()
  end

  defp governor_entries(limit) do
    GovernorEvent
    |> order_by([e], desc: e.seen_at)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(fn e ->
      %{
        id: e.id,
        at: e.seen_at,
        kind: "governor",
        summary: "#{e.action} #{e.network}/#{e.class}",
        detail: e.reason || e.identity_key,
        meta: %{
          network: e.network,
          class: e.class,
          action: e.action,
          identity_key: e.identity_key,
          reason: e.reason
        }
      }
    end)
  end

  defp gateway_entries(limit) do
    Activity
    |> order_by([a], desc: a.inserted_at)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(fn a ->
      %{
        id: a.id,
        at: a.inserted_at,
        kind: "gateway",
        summary: "#{a.from_network} → #{a.to_network} · #{a.status}",
        detail: a.error || short(a.from_ref) <> " → " <> short(a.to_ref),
        meta: %{
          status: a.status,
          from_network: a.from_network,
          to_network: a.to_network,
          error: a.error
        }
      }
    end)
  end

  defp sighting_entries(limit) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Sighting
    |> where([s], s.expires_at > ^now)
    |> order_by([s], desc: s.seen_at)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(fn s ->
      hops = if s.hops != nil, do: "hops=#{s.hops}", else: "hops=?"
      lat = if s.latency_ms, do: "#{s.latency_ms}ms", else: nil

      %{
        id: s.id,
        at: s.seen_at,
        kind: "sighting",
        summary: "#{s.network} #{s.direction} · #{hops}",
        detail:
          Enum.reject([short(s.identity_ref), lat, s.tunnel_id], &is_nil/1) |> Enum.join(" · "),
        meta: %{
          network: s.network,
          direction: s.direction,
          hops: s.hops,
          latency_ms: s.latency_ms,
          tunnel_id: s.tunnel_id
        }
      }
    end)
  end

  defp short(nil), do: "—"
  defp short(""), do: "—"

  defp short(ref) when is_binary(ref) do
    if String.length(ref) > 16 do
      String.slice(ref, 0, 8) <> "…" <> String.slice(ref, -4, 4)
    else
      ref
    end
  end

  defp normalize_kinds(kinds) when is_list(kinds) do
    kinds
    |> Enum.map(&to_string/1)
    |> Enum.filter(&(&1 in @kinds))
    |> Enum.uniq()
  end

  defp normalize_kinds(_), do: @kinds
end
