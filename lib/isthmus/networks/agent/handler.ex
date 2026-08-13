defmodule Isthmus.Networks.Agent.Handler do
  @moduledoc false
  @behaviour ExMCP.ACP.Client.Handler

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_session_update(_session_id, _update, state), do: {:ok, state}

  @impl true
  def handle_permission_request(_session_id, _tool_call, options, state) do
    reject =
      Enum.find(options, &(&1["kind"] == "reject_once")) ||
        Enum.find(options, &(&1["kind"] == "reject_always")) ||
        List.first(options)

    case reject do
      nil -> {:ok, %{"outcome" => "cancelled"}, state}
      option -> {:ok, %{"outcome" => "selected", "optionId" => option["optionId"]}, state}
    end
  end
end
