defmodule Isthmus.Gateway do
  @moduledoc "Gateway activity queries."

  import Ecto.Query
  alias Isthmus.Gateway.Activity
  alias Isthmus.Repo

  def list_recent(limit \\ 50) do
    Activity
    |> order_by([a], desc: a.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Recent forward attempts for admin UI — no message content.

  Returns maps with route/status metadata and `body_bytes` only.
  """
  def list_forward_log(limit \\ 50) do
    list_recent(limit) |> Enum.map(&public_row/1)
  end

  @doc "Failed / dropped gateway forwards for DLQ view."
  def list_dead(limit \\ 50) do
    Activity
    |> where([a], a.status in ["failed", "dropped"])
    |> order_by([a], desc: a.inserted_at)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(&public_row/1)
  end

  @doc """
  Aggregate gateway forward stats for the admin UI.
  """
  def stats do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    hour_ago = DateTime.add(now, -3_600, :second)
    day_ago = DateTime.add(now, -86_400, :second)

    %{
      total: count_all(),
      last_hour: count_since(hour_ago),
      last_24h: count_since(day_ago),
      by_status: count_grouped(:status),
      by_status_24h: count_grouped_since(:status, day_ago),
      by_route: count_routes(),
      by_route_24h: count_routes_since(day_ago)
    }
  end

  @doc "Most recent MeshCore peer pubkey seen for a registration (for reply routing)."
  def last_mesh_peer(group_id) when is_binary(group_id) do
    from(a in Activity,
      where:
        a.registration_group_id == ^group_id and a.from_network == "meshcore" and
          not is_nil(a.from_ref) and a.from_ref != "",
      order_by: [desc: a.inserted_at],
      limit: 1,
      select: a.from_ref
    )
    |> Repo.one()
  end

  @doc "Most recent Reticulum/LXMF peer destination hash for reply routing."
  def last_rns_peer(group_id) when is_binary(group_id) do
    from(a in Activity,
      where:
        a.registration_group_id == ^group_id and a.from_network == "reticulum" and
          not is_nil(a.from_ref) and a.from_ref != "",
      order_by: [desc: a.inserted_at],
      limit: 1,
      select: a.from_ref
    )
    |> Repo.one()
  end

  def log!(attrs) do
    %Activity{}
    |> Activity.changeset(attrs)
    |> Repo.insert!()
  end

  def log(attrs) do
    %Activity{}
    |> Activity.changeset(attrs)
    |> Repo.insert()
  end

  defp public_row(%Activity{} = a) do
    meta = a.meta || %{}

    body_bytes =
      case meta["body_bytes"] || meta[:body_bytes] do
        n when is_integer(n) and n >= 0 -> n
        _ -> byte_size(a.body || "")
      end

    %{
      id: a.id,
      inserted_at: a.inserted_at,
      direction: a.direction,
      from_network: a.from_network,
      to_network: a.to_network,
      from_ref: a.from_ref,
      to_ref: a.to_ref,
      status: a.status,
      error: a.error,
      external_id: a.external_id,
      registration_group_id: a.registration_group_id,
      body_bytes: body_bytes
    }
  end

  defp count_all do
    Repo.aggregate(Activity, :count, :id)
  end

  defp count_since(%DateTime{} = since) do
    from(a in Activity, where: a.inserted_at >= ^since)
    |> Repo.aggregate(:count, :id)
  end

  defp count_grouped(field) when is_atom(field) do
    from(a in Activity,
      group_by: field(a, ^field),
      select: {field(a, ^field), count(a.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp count_grouped_since(field, %DateTime{} = since) when is_atom(field) do
    from(a in Activity,
      where: a.inserted_at >= ^since,
      group_by: field(a, ^field),
      select: {field(a, ^field), count(a.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp count_routes do
    from(a in Activity,
      group_by: [a.from_network, a.to_network],
      select: {{a.from_network, a.to_network}, count(a.id)}
    )
    |> Repo.all()
    |> Enum.map(fn {{from, to}, n} -> %{from: from, to: to, count: n} end)
    |> Enum.sort_by(& &1.count, :desc)
  end

  defp count_routes_since(%DateTime{} = since) do
    from(a in Activity,
      where: a.inserted_at >= ^since,
      group_by: [a.from_network, a.to_network],
      select: {{a.from_network, a.to_network}, count(a.id)}
    )
    |> Repo.all()
    |> Enum.map(fn {{from, to}, n} -> %{from: from, to: to, count: n} end)
    |> Enum.sort_by(& &1.count, :desc)
  end
end
