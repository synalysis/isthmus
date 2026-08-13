defmodule IsthmusWeb.Plugs.CacheBodyReader do
  @moduledoc """
  Plug.Parsers body reader that keeps the raw `/mcp` body for ExMCP.HttpPlug.

  Phoenix parsers consume the adapter body; HttpPlug then re-reads it from
  `conn.assigns[:raw_body]`.
  """

  def read_body(conn, opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn, opts)

    conn =
      if mcp_path?(conn) do
        update_in(conn.assigns[:raw_body], fn
          nil -> body
          acc -> acc <> body
        end)
      else
        conn
      end

    {:ok, body, conn}
  end

  defp mcp_path?(%Plug.Conn{path_info: ["mcp" | _]}), do: true
  defp mcp_path?(_), do: false
end
