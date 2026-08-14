defmodule IsthmusWeb.HealthControllerTest do
  use IsthmusWeb.ConnCase, async: false

  test "liveness", %{conn: conn} do
    conn = get(conn, ~p"/healthz")
    assert json_response(conn, 200)["status"] == "ok"
  end

  test "readiness", %{conn: conn} do
    conn = get(conn, ~p"/readyz")
    assert json_response(conn, 200)["status"] == "ready"
  end

  test "deep readiness includes adapters", %{conn: conn} do
    conn = get(conn, ~p"/readyz?deep=1")
    body = json_response(conn, 200)
    assert body["status"] in ["ready", "degraded"]
    assert is_map(body["adapters"])
  end

  test "metrics endpoint", %{conn: conn} do
    conn = get(conn, ~p"/metrics")
    assert response(conn, 200)
    assert get_resp_header(conn, "content-type") |> hd() =~ "text/plain"
  end

  test "metrics is hidden when not public and no token", %{conn: conn} do
    restore_metrics_env()
    Application.put_env(:isthmus, :metrics_public, false)
    Application.put_env(:isthmus, :metrics_token, nil)

    conn = get(conn, ~p"/metrics")
    assert response(conn, 404)
  end

  test "metrics accepts a bearer token", %{conn: conn} do
    restore_metrics_env()
    Application.put_env(:isthmus, :metrics_public, false)
    Application.put_env(:isthmus, :metrics_token, "metrics-secret")

    conn =
      conn
      |> put_req_header("authorization", "Bearer metrics-secret")
      |> get(~p"/metrics")

    assert response(conn, 200)
  end

  test "deep readiness omits adapters without metrics access", %{conn: conn} do
    restore_metrics_env()
    Application.put_env(:isthmus, :metrics_public, false)
    Application.put_env(:isthmus, :metrics_token, nil)

    conn = get(conn, ~p"/readyz?deep=1")
    body = json_response(conn, 200)
    assert body["status"] == "ready"
    refute Map.has_key?(body, "adapters")
  end

  defp restore_metrics_env do
    prev_public = Application.get_env(:isthmus, :metrics_public)
    prev_token = Application.get_env(:isthmus, :metrics_token)

    on_exit(fn ->
      Application.put_env(:isthmus, :metrics_public, prev_public)
      Application.put_env(:isthmus, :metrics_token, prev_token)
    end)
  end
end
