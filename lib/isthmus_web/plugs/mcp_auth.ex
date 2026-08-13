defmodule IsthmusWeb.Plugs.McpAuth do
  @moduledoc "Bearer-token gate for the Isthmus MCP endpoint."
  import Plug.Conn

  def init(opts), do: opts

  def call(%Plug.Conn{method: "OPTIONS"} = conn, _opts) do
    if Isthmus.MCP.enabled?(), do: conn, else: reject(conn, 404, "MCP is disabled")
  end

  def call(conn, _opts) do
    cond do
      not Isthmus.MCP.enabled?() ->
        reject(conn, 404, "MCP is disabled")

      is_nil(Isthmus.MCP.token()) ->
        reject(conn, 401, "Set ISTHMUS_MCP_TOKEN to enable the MCP control plane")

      bearer(conn) == Isthmus.MCP.token() ->
        conn

      true ->
        reject(conn, 401, "Authorization required")
    end
  end

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> String.trim(token)
      ["bearer " <> token] -> String.trim(token)
      _ -> nil
    end
  end

  defp reject(conn, status, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: message}))
    |> halt()
  end
end
