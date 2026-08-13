defmodule IsthmusWeb.MCPTest do
  use IsthmusWeb.ConnCase, async: false

  @token "test-mcp-token"

  test "rejects missing bearer token", %{conn: conn} do
    conn = post_mcp(conn, rpc("initialize"), [])
    assert json_response(conn, 401)["error"] =~ "Authorization"
  end

  test "rejects the wrong bearer token", %{conn: conn} do
    conn = post_mcp(conn, rpc("initialize"), [{"authorization", "Bearer nope"}])
    assert json_response(conn, 401)["error"] =~ "Authorization"
  end

  test "returns 404 when MCP is disabled", %{conn: conn} do
    previous = Application.get_env(:isthmus, Isthmus.MCP, [])

    on_exit(fn ->
      Application.put_env(:isthmus, Isthmus.MCP, previous)
    end)

    Application.put_env(:isthmus, Isthmus.MCP, enabled: false, token: @token)

    conn = post_mcp(conn, rpc("initialize"), [{"authorization", "Bearer #{@token}"}])
    assert json_response(conn, 404)["error"] =~ "disabled"
  end

  test "initialize and tools/list with a valid bearer token", %{conn: conn} do
    auth = [{"authorization", "Bearer #{@token}"}]

    conn = post_mcp(conn, rpc("initialize"), auth)
    body = json_response(conn, 200)
    assert body["result"]["serverInfo"]["name"] == "isthmus"
    session = mcp_session(conn)

    conn =
      build_conn()
      |> post_mcp(rpc("tools/list", %{}, 2), auth ++ session_header(session))

    tools = json_response(conn, 200)["result"]["tools"]
    names = Enum.map(tools, & &1["name"])
    assert "list_groups" in names
    assert "inject_message" in names
  end

  defp post_mcp(conn, payload, headers) do
    conn =
      Enum.reduce(headers, conn, fn {key, value}, acc ->
        put_req_header(acc, key, value)
      end)

    conn
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json")
    |> post("/mcp", Jason.encode!(payload))
  end

  defp rpc(method, params \\ %{}, id \\ 1)

  defp rpc("initialize", params, id) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "initialize",
      "params" =>
        Map.merge(
          %{
            "protocolVersion" => "2025-03-26",
            "capabilities" => %{},
            "clientInfo" => %{"name" => "isthmus-test", "version" => "0"}
          },
          params
        )
    }
  end

  defp rpc(method, params, id) do
    %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
  end

  defp mcp_session(conn) do
    case get_resp_header(conn, "mcp-session-id") do
      [id | _] -> id
      [] -> nil
    end
  end

  defp session_header(nil), do: []
  defp session_header(id), do: [{"mcp-session-id", id}]
end
