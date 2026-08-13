defmodule Isthmus.MCP.ServerTest do
  use Isthmus.DataCase, async: false

  alias Isthmus.MCP.Server

  test "lists operator tools over the BEAM transport" do
    server =
      start_supervised!({Server, transport: :beam, protocol_mode: :prefer_modern})

    client =
      start_supervised!(
        {ExMCP.Client, transport: :beam, server: server, protocol_mode: :prefer_modern}
      )

    assert {:ok, listed} = ExMCP.Client.list_tools(client, format: :map)
    names = Enum.map(listed["tools"] || listed[:tools], &(&1["name"] || &1[:name]))
    assert "health" in names
    assert "list_groups" in names
    assert "inject_message" in names
    assert "set_policy" in names

    assert {:ok, result} = ExMCP.Client.call_tool(client, "health", %{}, format: :map)
    text = tool_text(result)
    assert text =~ "reports"
  end

  defp tool_text(%{"content" => [%{"text" => text} | _]}), do: text
  defp tool_text(%{content: [%{text: text} | _]}), do: text
  defp tool_text(other), do: inspect(other)
end
