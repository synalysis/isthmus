defmodule IsthmusWeb.Admin.TimelineLive do
  use IsthmusWeb, :live_view

  alias Isthmus.Audit

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(3_000, self(), :refresh)

    {:ok,
     socket
     |> assign(:page_title, "Timeline")
     |> assign_data()}
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, assign_data(socket)}

  defp assign_data(socket) do
    assign(socket, :entries, Audit.timeline(80))
  end

  defp kind_badge("governor"), do: {"governor", "badge-warning"}
  defp kind_badge("gateway"), do: {"gateway", "badge-info"}
  defp kind_badge("sighting"), do: {"sighting", "badge-success"}
  defp kind_badge(other), do: {other, "badge-ghost"}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <section class="space-y-6">
        <div class="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
          <div>
            <h1 class="text-3xl font-semibold">Ops timeline</h1>
            <p class="mt-1 text-sm text-base-content/70">
              Unified view of announces, gateway forwards, and governor decisions.
            </p>
          </div>
          <.admin_nav current={:timeline} />
        </div>

        <div class="overflow-x-auto rounded-box border border-base-300" id="ops-timeline">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>When</th>
                <th>Kind</th>
                <th>Summary</th>
                <th>Detail</th>
              </tr>
            </thead>
            <tbody>
              <tr :if={@entries == []}>
                <td colspan="4" class="text-sm opacity-60">No recent activity.</td>
              </tr>
              <tr :for={e <- @entries}>
                <td class="whitespace-nowrap text-xs font-mono">{e.at}</td>
                <td>
                  <% {label, class} = kind_badge(e.kind) %>
                  <span class={["badge badge-sm", class]}>{label}</span>
                </td>
                <td class="text-sm">{e.summary}</td>
                <td class="text-xs font-mono opacity-70 max-w-md truncate" title={e.detail}>
                  {e.detail}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
