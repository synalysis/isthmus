defmodule IsthmusWeb.MetricsAuth do
  @moduledoc "Shared gate for `/metrics` and deep `/readyz`."

  import Plug.Conn

  @spec allowed?(Plug.Conn.t()) :: boolean()
  def allowed?(conn) do
    case Application.get_env(:isthmus, :metrics_token) do
      token when is_binary(token) and token != "" ->
        case bearer(conn) do
          provided when is_binary(provided) ->
            Plug.Crypto.secure_compare(provided, token)

          _ ->
            false
        end

      _ ->
        Application.get_env(:isthmus, :metrics_public, true) == true
    end
  end

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> String.trim(token)
      ["bearer " <> token] -> String.trim(token)
      _ -> nil
    end
  end
end
