defmodule Isthmus.Networks.AgentTest do
  use ExUnit.Case, async: true

  alias Isthmus.Networks.Agent
  alias Isthmus.Networks.Agent.Bridge
  alias Isthmus.Networks.Agent.Handler
  alias Isthmus.Networks.Health

  test "parse_identity_ref accepts a short ACP name" do
    assert {:ok, "cursor", %{name: "cursor"}} = Agent.parse_identity_ref("Cursor")
    assert {:ok, "ops-bot", _} = Agent.parse_identity_ref("@ops-bot")
    assert {:error, :invalid_agent_identity} = Agent.parse_identity_ref("no spaces")
    assert {:error, :invalid_agent_identity} = Agent.parse_identity_ref("1leadingdigit")
  end

  test "health is disabled in the test env" do
    health = Agent.health()
    assert health.status == :disabled

    report = Health.normalize(:agent, health)
    assert report.status == :disabled
    assert report.label == "ACP agent"
  end

  test "prompt fails when the ACP subprocess is disabled" do
    assert {:error, :not_connected} = Bridge.prompt("cursor", "hello")
  end

  test "permission requests pick a reject option" do
    {:ok, state} = Handler.init([])

    options = [
      %{"kind" => "allow_once", "optionId" => "allow"},
      %{"kind" => "reject_once", "optionId" => "reject"}
    ]

    assert {:ok, %{"outcome" => "selected", "optionId" => "reject"}, _} =
             Handler.handle_permission_request("s1", %{}, options, state)
  end
end
