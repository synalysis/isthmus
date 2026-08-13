defmodule Isthmus.MCP do
  @moduledoc """
  Isthmus MCP control plane.

  Exposes operator tools over Streamable HTTP at `/mcp` so an MCP client
  (Cursor, Claude, etc.) can inspect and drive this instance. Gate with
  `ISTHMUS_MCP_TOKEN`.
  """

  @spec enabled?() :: boolean()
  def enabled? do
    Keyword.get(env(), :enabled, true) != false
  end

  @spec token() :: String.t() | nil
  def token do
    case Keyword.get(env(), :token) do
      token when is_binary(token) and token != "" -> token
      _ -> nil
    end
  end

  @spec configured?() :: boolean()
  def configured? do
    enabled?() and is_binary(token())
  end

  defp env, do: Application.get_env(:isthmus, __MODULE__, [])
end
