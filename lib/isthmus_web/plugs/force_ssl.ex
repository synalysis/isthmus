defmodule IsthmusWeb.Plugs.ForceSSL do
  @moduledoc """
  Runtime SSL redirect.

  Phoenix.Endpoint reads `:force_ssl` via `Application.compile_env/2`, so a
  release cannot turn it off with `FORCE_SSL`. This plug reads `:isthmus,
  :force_ssl` from `runtime.exs` instead.
  """
  @behaviour Plug

  def init(opts), do: opts

  def call(conn, _opts) do
    case Application.get_env(:isthmus, :force_ssl) do
      ssl_opts when is_list(ssl_opts) ->
        ssl_opts = Keyword.put_new(ssl_opts, :host, {IsthmusWeb.Endpoint, :host, []})
        Plug.SSL.call(conn, Plug.SSL.init(ssl_opts))

      _ ->
        conn
    end
  end
end
