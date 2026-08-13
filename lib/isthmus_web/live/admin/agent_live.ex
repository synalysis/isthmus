defmodule IsthmusWeb.Admin.AgentLive do
  use IsthmusWeb, :live_view

  alias Isthmus.Networks.Agent
  alias Isthmus.Networks.Agent.Settings
  alias Isthmus.Networks.Health

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(3_000, self(), :refresh)

    {:ok,
     socket
     |> assign(:page_title, "ACP agent")
     |> assign_page()}
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, assign_health(socket)}

  @impl true
  def handle_event("validate", %{"acp" => params}, socket) do
    params = apply_preset(params)
    {:noreply, assign(socket, :form, to_form(params, as: :acp))}
  end

  def handle_event("save", %{"acp" => params}, socket) do
    case Settings.apply(apply_preset(params)) do
      {:ok, health} ->
        {:noreply,
         socket
         |> put_flash(:info, reconnect_flash(health))
         |> assign_page()}

      {:error, :blank_command} ->
        {:noreply,
         socket
         |> put_flash(:error, "Command is required when the ACP agent is enabled.")
         |> assign(:form, to_form(apply_preset(params), as: :acp))}
    end
  end

  defp assign_page(socket) do
    settings = Settings.current()

    socket
    |> assign(:settings, settings)
    |> assign(:form, to_form(Settings.form_params(settings), as: :acp))
    |> assign(:preset_options, Settings.preset_options())
    |> assign_health()
  end

  defp assign_health(socket) do
    health = Agent.health()
    report = Health.normalize(:agent, health)

    socket
    |> assign(:health, health)
    |> assign(:report, report)
  end

  defp apply_preset(params) do
    preset = params["preset"] || "custom"

    command =
      case Enum.find(Settings.presets(), &(&1.id == preset)) do
        %{command: command} -> command
        nil -> params["command"] || ""
      end

    params
    |> Map.put("command", command)
    |> Map.put("preset", Settings.preset_id(command))
  end

  defp reconnect_flash(%{status: :online} = health) do
    cmd = health[:command] || health["command"] || Settings.current().command
    "ACP agent connected via #{cmd}."
  end

  defp reconnect_flash(%{status: :disabled}) do
    "ACP agent disabled. Settings saved."
  end

  defp reconnect_flash(health) do
    err = health[:last_error] || health["last_error"]
    base = "ACP settings saved (#{health[:status] || health["status"] || "unknown"})."
    if is_binary(err) and err != "", do: "#{base} #{err}", else: base
  end

  defp severity_badge(:ok), do: {"ok", "badge-success"}
  defp severity_badge(:info), do: {"info", "badge-ghost"}
  defp severity_badge(:warn), do: {"degraded", "badge-warning"}
  defp severity_badge(:error), do: {"error", "badge-error"}
  defp severity_badge(_), do: {"unknown", "badge-ghost"}

  defp source_label(:policy), do: "Saved in Isthmus (Admin → ACP)"
  defp source_label(:config), do: "Boot default (config / ISTHMUS_ACP_* env)"
  defp source_label(_), do: "Boot default"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <section class="space-y-8">
        <.admin_header current={:agent} title="ACP agent">
          Isthmus is the ACP client. It spawns one agent subprocess and prompts it
          with group traffic. Attach a member under Groups to fan replies back to
          radio / Nostr / RNS.
        </.admin_header>

        <article class="rounded-box border border-base-300 bg-base-200 p-4 space-y-3" id="acp-status">
          <div class="flex items-start justify-between gap-3">
            <div>
              <h2 class="text-lg font-semibold">Status</h2>
              <p class="text-sm opacity-70 mt-0.5">{@report.summary}</p>
            </div>
            <% {badge_label, badge_class} = severity_badge(@report.severity) %>
            <span class={["badge badge-sm shrink-0", badge_class]}>{badge_label}</span>
          </div>
          <dl class="grid grid-cols-2 gap-x-3 gap-y-1 text-xs opacity-70">
            <dt class="font-medium">Command</dt>
            <dd class="font-mono truncate">{@settings.command}</dd>
            <dt class="font-medium">Source</dt>
            <dd>{source_label(@settings.source)}</dd>
            <dt :if={@settings.cwd} class="font-medium">Working dir</dt>
            <dd :if={@settings.cwd} class="font-mono truncate">{@settings.cwd}</dd>
          </dl>
          <div :if={@report.issue} class="rounded-lg bg-base-300/60 px-3 py-2 text-sm space-y-1">
            <p class="font-medium text-warning">{@report.issue}</p>
            <p :if={@report.fix} class="opacity-80">{@report.fix}</p>
          </div>
        </article>

        <.form
          for={@form}
          id="acp-settings-form"
          phx-change="validate"
          phx-submit="save"
          class="rounded-box border border-base-300 bg-base-200 p-4 space-y-4 max-w-xl"
        >
          <div>
            <h2 class="text-lg font-medium">Agent subprocess</h2>
            <p class="text-sm opacity-70 mt-1">
              One command for the whole instance. Group member names
              (<code class="font-mono text-xs">cursor</code>, <code class="font-mono text-xs">hermes</code>) are session labels,
              not a second binary. Presets are native ACP CLIs on PATH.
              Switching here replaces the running agent.
            </p>
          </div>

          <.input field={@form[:enabled]} type="checkbox" label="Spawn ACP agent" />
          <.input
            field={@form[:preset]}
            type="select"
            label="Preset"
            options={@preset_options}
          />
          <.input
            field={@form[:command]}
            type="text"
            label="Command"
            placeholder="agent acp"
            autocomplete="off"
            readonly={to_string(@form[:preset].value) != "custom"}
          />
          <.input
            field={@form[:cwd]}
            type="text"
            label="Working directory (optional)"
            placeholder="Isthmus project directory"
            autocomplete="off"
          />
          <button class="btn btn-primary btn-sm" type="submit" id="acp-apply">
            Apply & reconnect
          </button>
        </.form>
      </section>
    </Layouts.app>
    """
  end
end
