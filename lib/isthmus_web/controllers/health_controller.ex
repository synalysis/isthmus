defmodule IsthmusWeb.HealthController do
  use IsthmusWeb, :controller

  alias Isthmus.Repo

  @doc "Liveness — process is up."
  def liveness(conn, _params) do
    json(conn, %{status: "ok"})
  end

  @doc """
  Readiness — database reachable.

  With `?deep=1`, also reports adapter status. Returns 503 only when the DB is down;
  degraded adapters are reported as `status: "degraded"` with HTTP 200 so load balancers
  can keep serving while ops investigate.
  """
  def readiness(conn, params) do
    case Ecto.Adapters.SQL.query(Repo, "SELECT 1", []) do
      {:ok, _} ->
        if params["deep"] in ["1", "true"] and IsthmusWeb.MetricsAuth.allowed?(conn) do
          adapters = safe_adapter_health()
          degraded? = Enum.any?(adapters, fn {_k, v} -> degraded_status?(v) end)

          payload = %{
            status: if(degraded?, do: "degraded", else: "ready"),
            adapters: adapters
          }

          json(conn, payload)
        else
          json(conn, %{status: "ready"})
        end

      {:error, reason} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{status: "not_ready", error: inspect(reason)})
    end
  end

  defp safe_adapter_health do
    try do
      Isthmus.Networks.health_all()
      |> Map.new(fn {id, health} ->
        {id, Map.take(health, [:status, :detail, :port, :last_error, :online, :connections])}
      end)
    rescue
      e -> %{error: Exception.message(e)}
    catch
      :exit, reason -> %{error: inspect(reason)}
    end
  end

  defp degraded_status?(health) when is_map(health) do
    status = health[:status] || health["status"]
    status in [:error, :crashed, :disconnected, "error", "crashed", "disconnected"]
  end

  defp degraded_status?(_), do: false
end
