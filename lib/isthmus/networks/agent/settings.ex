defmodule Isthmus.Networks.Agent.Settings do
  @moduledoc """
  Effective ACP spawn settings.

  Isthmus runs **one** ACP subprocess. Group member identity (`cursor`, `hermes`, …)
  is a session name on that process, not a choice of binary.

  Precedence: values saved from Admin → ACP (policy) override `config.exs` /
  `ISTHMUS_ACP_*` after hydrate-on-boot or an Apply in the UI.
  """

  alias Isthmus.Policy

  @app :isthmus
  @env_key Isthmus.Networks.Agent

  @presets [
    %{id: "cursor", label: "Cursor", command: "agent acp"},
    %{id: "hermes", label: "Hermes", command: "hermes acp"},
    %{id: "gemini", label: "Gemini CLI", command: "gemini --acp"},
    %{id: "opencode", label: "OpenCode", command: "opencode acp"},
    %{id: "goose", label: "Goose", command: "goose acp"},
    %{id: "copilot", label: "GitHub Copilot", command: "copilot --acp"},
    %{id: "cline", label: "Cline", command: "cline --acp"},
    %{id: "qwen", label: "Qwen Code", command: "qwen --acp"},
    %{id: "auggie", label: "Auggie", command: "auggie --acp"}
  ]

  def presets, do: @presets

  def preset_options do
    Enum.map(@presets, &{&1.label <> " (`#{&1.command}`)", &1.id}) ++ [{"Custom", "custom"}]
  end

  @doc "Currently running settings (Application env)."
  def current do
    opts = env()
    command = command_argv(opts)
    command_string = Enum.join(command, " ")

    %{
      enabled: Keyword.get(opts, :enabled, true) != false and command != [],
      command: command_string,
      command_argv: command,
      cwd: cwd(opts),
      preset: preset_id(command_string),
      source: source(),
      prompt_timeout_ms: Keyword.get(opts, :prompt_timeout_ms, 120_000)
    }
  end

  def form_params(settings \\ current()) do
    %{
      "enabled" => settings.enabled,
      "preset" => settings.preset,
      "command" => settings.command,
      "cwd" => settings.cwd || ""
    }
  end

  @doc "Persist to policy, update Application env, and reconnect the ACP client."
  def apply(params) when is_map(params) do
    with {:ok, attrs} <- cast(params) do
      persist!(attrs)
      put_env!(attrs)

      case Isthmus.Networks.Agent.Bridge.reconnect() do
        {:ok, health} -> {:ok, health}
        {:error, reason} -> {:ok, %{status: :error, last_error: inspect(reason)}}
      end
    end
  end

  @doc "Copy policy overrides into Application env (boot). No-op when unset."
  def hydrate_from_policy do
    case policy_override() do
      nil -> :ok
      attrs -> put_env!(attrs)
    end
  end

  def command_argv(opts \\ env()) do
    case Keyword.get(opts, :command, ["agent", "acp"]) do
      list when is_list(list) -> Enum.filter(list, &(is_binary(&1) and &1 != ""))
      bin when is_binary(bin) -> split_command(bin)
      _ -> []
    end
  end

  def split_command(command) when is_binary(command) do
    command
    |> String.trim()
    |> String.split(~r/\s+/, trim: true)
  end

  def split_command(_), do: []

  def preset_id(command) when is_binary(command) do
    case Enum.find(@presets, &(&1.command == String.trim(command))) do
      %{id: id} -> id
      nil -> "custom"
    end
  end

  defp cast(params) do
    enabled = truthy?(param(params, :enabled))
    preset = params |> param(:preset) |> to_string() |> String.trim()

    command =
      case preset_command(preset) do
        "" -> params |> param(:command) |> to_string() |> String.trim()
        known -> known
      end

    cwd =
      case params |> param(:cwd) |> to_string() |> String.trim() do
        "" -> nil
        path -> path
      end

    argv = split_command(command)

    cond do
      enabled and argv == [] ->
        {:error, :blank_command}

      true ->
        {:ok,
         %{
           enabled: enabled,
           command: command,
           command_argv: argv,
           cwd: cwd
         }}
    end
  end

  defp persist!(attrs) do
    {:ok, _} = Policy.put("acp_enabled", attrs.enabled)
    {:ok, _} = Policy.put("acp_command", attrs.command)
    {:ok, _} = Policy.put("acp_cwd", attrs.cwd || "")
    :ok
  end

  defp put_env!(attrs) do
    merged =
      env()
      |> Keyword.put(:enabled, attrs.enabled)
      |> Keyword.put(:command, attrs.command_argv)
      |> Keyword.put(:cwd, attrs.cwd)

    Application.put_env(@app, @env_key, merged)
    :ok
  end

  defp policy_override do
    enabled = policy_get("acp_enabled")
    command = policy_get("acp_command")
    cwd = policy_get("acp_cwd")

    if is_nil(enabled) and is_nil(command) and is_nil(cwd) do
      nil
    else
      command_s =
        case command do
          s when is_binary(s) -> String.trim(s)
          _ -> current().command
        end

      cwd_s =
        case cwd do
          s when is_binary(s) ->
            trimmed = String.trim(s)
            if trimmed == "", do: nil, else: trimmed

          _ ->
            current().cwd
        end

      enabled? =
        case enabled do
          v when is_boolean(v) -> v
          _ -> current().enabled
        end

      %{
        enabled: enabled?,
        command: command_s,
        command_argv: split_command(command_s),
        cwd: cwd_s
      }
    end
  end

  defp source do
    if policy_get("acp_command") != nil or policy_get("acp_enabled") != nil or
         policy_get("acp_cwd") != nil do
      :policy
    else
      :config
    end
  end

  defp policy_get(key) do
    Policy.get(key)
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  defp env, do: Application.get_env(@app, @env_key, [])

  defp cwd(opts) do
    case Keyword.get(opts, :cwd) do
      cwd when is_binary(cwd) and cwd != "" -> cwd
      _ -> nil
    end
  end

  defp preset_command(id) do
    case Enum.find(@presets, &(&1.id == id)) do
      %{command: command} -> command
      nil -> ""
    end
  end

  defp param(params, key) when is_atom(key) do
    Map.get(params, key) || Map.get(params, Atom.to_string(key))
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?("1"), do: true
  defp truthy?(_), do: false
end
