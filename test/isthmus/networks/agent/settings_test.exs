defmodule Isthmus.Networks.Agent.SettingsTest do
  use Isthmus.DataCase, async: false

  alias Isthmus.Networks.Agent.Bridge
  alias Isthmus.Networks.Agent.Settings
  alias Isthmus.Policy

  setup do
    previous = Application.get_env(:isthmus, Isthmus.Networks.Agent)

    on_exit(fn ->
      Application.put_env(:isthmus, Isthmus.Networks.Agent, previous)
      _ = Bridge.reconnect()
    end)

    :ok
  end

  test "preset_id maps native ACP commands" do
    assert Settings.preset_id("agent acp") == "cursor"
    assert Settings.preset_id("hermes acp") == "hermes"
    assert Settings.preset_id("gemini --acp") == "gemini"
    assert Settings.preset_id("opencode acp") == "opencode"
    assert Settings.preset_id("goose acp") == "goose"
    assert Settings.preset_id("copilot --acp") == "copilot"
    assert Settings.preset_id("cline --acp") == "cline"
    assert Settings.preset_id("qwen --acp") == "qwen"
    assert Settings.preset_id("auggie --acp") == "auggie"
    assert Settings.preset_id("npx some-agent --acp") == "custom"
  end

  test "native ACP presets have unique ids and commands" do
    ids = Enum.map(Settings.presets(), & &1.id)
    cmds = Enum.map(Settings.presets(), & &1.command)
    assert ids == Enum.uniq(ids)
    assert cmds == Enum.uniq(cmds)

    for %{id: id, command: command} <- Settings.presets() do
      assert Settings.preset_id(command) == id
    end
  end

  test "apply persists Hermes command without enabling the subprocess" do
    assert {:ok, health} =
             Settings.apply(%{
               "enabled" => "false",
               "preset" => "hermes",
               "command" => "ignored",
               "cwd" => ""
             })

    assert health.status == :disabled
    assert Policy.get("acp_command") == "hermes acp"
    assert Policy.get("acp_enabled") == false

    current = Settings.current()
    assert current.command == "hermes acp"
    assert current.command_argv == ["hermes", "acp"]
    assert current.preset == "hermes"
    assert current.enabled == false
    assert current.source == :policy
  end

  test "apply maps the Gemini preset to gemini --acp" do
    assert {:ok, _} =
             Settings.apply(%{
               "enabled" => "false",
               "preset" => "gemini",
               "command" => "ignored",
               "cwd" => ""
             })

    assert Policy.get("acp_command") == "gemini --acp"
    assert Settings.current().command_argv == ["gemini", "--acp"]
    assert Settings.current().preset == "gemini"
  end

  test "hydrate_from_policy copies saved command into Application env" do
    {:ok, _} = Policy.put("acp_enabled", false)
    {:ok, _} = Policy.put("acp_command", "hermes acp")
    {:ok, _} = Policy.put("acp_cwd", "/tmp")

    Application.put_env(:isthmus, Isthmus.Networks.Agent,
      enabled: false,
      command: [],
      cwd: nil
    )

    assert :ok = Settings.hydrate_from_policy()
    assert Settings.current().command == "hermes acp"
    assert Settings.current().cwd == "/tmp"
  end

  test "apply rejects a blank command when enabled" do
    assert {:error, :blank_command} =
             Settings.apply(%{"enabled" => "true", "preset" => "custom", "command" => "  "})
  end

  test "a missing ACP binary is a stable error, not a spawn loop" do
    Application.put_env(:isthmus, Isthmus.Networks.Agent,
      enabled: true,
      command: ["isthmus-missing-acp-binary"],
      cwd: nil
    )

    assert {:ok, health} = Bridge.reconnect()
    assert health.status == :error
    assert health.last_error =~ "not found"
  end
end
