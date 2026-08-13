defmodule IsthmusWeb.Plugs.McpSse do
  @moduledoc """
  Streamable HTTP GET (`Accept: text/event-stream`) from the Bandit request process.

  `ExMCP.HttpPlug.SSEHandler` chunks from a GenServer. Bandit 1.12 raises
  `Adapter functions must be called by stream owner`, which Cursor reports as a
  failed MCP connection (then SSE fallback / ECONNREFUSED).
  """
  import Plug.Conn

  @keepalive_ms 15_000

  def init(opts), do: opts

  def call(%Plug.Conn{method: "GET"} = conn, _opts) do
    if sse?(conn), do: serve(conn), else: conn
  end

  def call(conn, _opts), do: conn

  defp sse?(conn) do
    conn
    |> get_req_header("accept")
    |> Enum.any?(&String.contains?(&1, "text/event-stream"))
  end

  defp serve(conn) do
    session_id =
      case get_req_header(conn, "mcp-session-id") do
        [id | _] -> id
        _ -> nil
      end

    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> put_resp_header("x-accel-buffering", "no")
      |> maybe_session_header(session_id)
      |> send_chunked(200)

    case chunk(conn, ": connected\n\n") do
      {:ok, conn} ->
        if Application.get_env(:isthmus, :mcp_sse_hold, true) do
          hold(conn)
        else
          halt(conn)
        end

      {:error, _} ->
        halt(conn)
    end
  end

  defp maybe_session_header(conn, nil), do: conn

  defp maybe_session_header(conn, session_id),
    do: put_resp_header(conn, "mcp-session-id", session_id)

  defp hold(conn) do
    receive do
      {:plug_conn, :sent} ->
        hold(conn)
    after
      @keepalive_ms ->
        case chunk(conn, ": keepalive\n\n") do
          {:ok, conn} -> hold(conn)
          {:error, _} -> halt(conn)
        end
    end
  end
end
