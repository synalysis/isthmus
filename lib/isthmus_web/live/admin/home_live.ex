defmodule IsthmusWeb.Admin.HomeLive do
  use IsthmusWeb, :live_view

  alias Isthmus.Gateway
  alias Isthmus.Networks.Health
  alias Isthmus.Policy
  alias Isthmus.Registrations
  alias Isthmus.Relays

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(3_000, self(), :refresh)

    {:ok,
     socket
     |> assign(:page_title, "Admin")
     |> assign_ops()}
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, assign_ops(socket)}

  @impl true
  def handle_event("toggle_registration", _params, socket) do
    new_value = !socket.assigns.registration_open
    {:ok, _} = Policy.put("registration_open", new_value)
    {:noreply, assign(socket, :registration_open, new_value)}
  end

  defp assign_ops(socket) do
    reports = Health.report_all()
    problems = Enum.filter(reports, &(&1.severity in [:error, :warn] and &1.issue))

    gw = Gateway.stats()

    socket
    |> assign(:reports, reports)
    |> assign(:problems, problems)
    |> assign(:relay_count, length(Relays.list_relays()))
    |> assign(:registration_count, length(Registrations.list_all()))
    |> assign(:registration_open, Policy.registration_open?())
    |> assign(:gateway_24h, gw.last_24h)
    |> assign(:gateway_delivered_24h, Map.get(gw.by_status_24h, "delivered", 0))
  end

  defp severity_badge(:ok), do: {"ok", "badge-success"}
  defp severity_badge(:info), do: {"info", "badge-ghost"}
  defp severity_badge(:warn), do: {"degraded", "badge-warning"}
  defp severity_badge(:error), do: {"error", "badge-error"}
  defp severity_badge(_), do: {"unknown", "badge-ghost"}

  defp card_border(:error), do: "border-error/60"
  defp card_border(:warn), do: "border-warning/60"
  defp card_border(_), do: "border-base-300"

  defp network_setup_link(:nostr), do: {~p"/admin/nostr", "Open Nostr setup →"}
  defp network_setup_link(:meshcore), do: {~p"/admin/meshcore", "Open MeshCore setup →"}
  defp network_setup_link(:meshtastic), do: {~p"/admin/meshtastic", "Open Meshtastic setup →"}
  defp network_setup_link(:reticulum), do: {~p"/admin/reticulum", "Open Reticulum setup →"}
  defp network_setup_link(_), do: nil

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <section class="space-y-8">
        <.admin_header current={:home} title="Admin">
          Ops control plane for Isthmus.
        </.admin_header>

        <div :if={@problems != []} class="space-y-3">
          <div :for={p <- @problems} class="alert alert-warning text-sm items-start">
            <div>
              <p class="font-semibold">{p.label}: {p.issue}</p>
              <p :if={p.fix} class="mt-1 opacity-90">{p.fix}</p>
            </div>
          </div>
        </div>

        <div class="space-y-3">
          <div class="flex items-baseline justify-between gap-3">
            <h2 class="text-xl font-medium">Networks</h2>
            <p class="text-xs opacity-50">Refreshes every 3s</p>
          </div>

          <div class="grid gap-3 md:grid-cols-2">
            <article
              :for={r <- @reports}
              class={["rounded-box border bg-base-200 p-4 space-y-3", card_border(r.severity)]}
            >
              <div class="flex items-start justify-between gap-3">
                <div>
                  <h3 class="text-lg font-semibold">{r.label}</h3>
                  <p class="text-sm opacity-70 mt-0.5">{r.summary}</p>
                </div>
                <% {badge_label, badge_class} = severity_badge(r.severity) %>
                <span class={["badge badge-sm shrink-0", badge_class]}>{badge_label}</span>
              </div>

              <dl :if={r.meta != []} class="grid grid-cols-2 gap-x-3 gap-y-1 text-xs opacity-70">
                <div :for={{k, v} <- r.meta} class="contents">
                  <dt class="font-medium">{k}</dt>
                  <dd class="font-mono truncate">{v}</dd>
                </div>
              </dl>

              <div :if={r.issue} class="rounded-lg bg-base-300/60 px-3 py-2 text-sm space-y-1">
                <p class="font-medium text-warning">{r.issue}</p>
                <p :if={r.fix} class="opacity-80">{r.fix}</p>
              </div>

              <div :if={link = network_setup_link(r.network)} class="pt-1">
                <% {href, label} = link %>
                <.link navigate={href} class="link link-hover text-sm">{label}</.link>
              </div>
            </article>
          </div>
        </div>

        <div class="grid gap-4 md:grid-cols-2 xl:grid-cols-4">
          <div class="stat bg-base-200 rounded-box border border-base-300">
            <div class="stat-title">Relays</div>
            <div class="stat-value text-2xl">{@relay_count}</div>
            <div class="stat-desc">
              <.link navigate={~p"/admin/nostr"} class="link link-hover">Nostr setup</.link>
            </div>
          </div>
          <div class="stat bg-base-200 rounded-box border border-base-300">
            <div class="stat-title">Registrations</div>
            <div class="stat-value text-2xl">{@registration_count}</div>
            <div class="stat-desc">
              <.link navigate={~p"/admin/registrations"} class="link link-hover">Groups</.link>
            </div>
          </div>
          <div class="stat bg-base-200 rounded-box border border-base-300">
            <div class="stat-title">Forwards (24h)</div>
            <div class="stat-value text-2xl">{@gateway_24h}</div>
            <div class="stat-desc">
              {@gateway_delivered_24h} delivered ·
              <.link navigate={~p"/admin/gateway"} class="link link-hover">view log</.link>
            </div>
          </div>
          <div class="stat bg-base-200 rounded-box border border-base-300">
            <div class="stat-title">Self-service</div>
            <div class="stat-value text-2xl">{if @registration_open, do: "Open", else: "Closed"}</div>
            <div class="stat-actions">
              <button class="btn btn-sm" phx-click="toggle_registration">Toggle</button>
            </div>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
