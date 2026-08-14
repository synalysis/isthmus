defmodule IsthmusWeb.MetricsController do
  use IsthmusWeb, :controller

  def index(conn, _params) do
    if IsthmusWeb.MetricsAuth.allowed?(conn) do
      metrics = TelemetryMetricsPrometheus.Core.scrape()

      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(200, metrics)
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(404, "not found")
    end
  end
end
