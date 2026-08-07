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
end
