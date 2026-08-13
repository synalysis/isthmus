defmodule IsthmusWeb.Admin.AuditLive do
  use IsthmusWeb, :live_view

  alias Isthmus.Audit

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(5_000, self(), :refresh)

    {:ok,
     socket
     |> assign(:page_title, "Audit")
     |> assign_data()}
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, assign_data(socket)}

  defp assign_data(socket) do
    assign(socket, :events, Audit.governor_recent(100))
  end

  defp action_badge("drop"), do: {"drop", "badge-error"}
  defp action_badge("allow"), do: {"allow", "badge-success"}
  defp action_badge(other), do: {other || "?", "badge-ghost"}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <section class="space-y-6">
        <.admin_header current={:audit} title="Governor audit">
          Allow / drop decisions across announce, tunnel, and gateway classes.
        </.admin_header>

        <div class="overflow-x-auto rounded-box border border-base-300" id="governor-audit">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>When</th>
                <th>Action</th>
                <th>Network</th>
                <th>Class</th>
                <th>Identity</th>
                <th>Reason</th>
              </tr>
            </thead>
            <tbody>
              <tr :if={@events == []}>
                <td colspan="6" class="text-sm opacity-60">No governor events yet.</td>
              </tr>
              <tr :for={e <- @events}>
                <td>
                  <.local_time id={"audit-when-#{e.id}"} at={e.seen_at} />
                </td>
                <td>
                  <% {label, class} = action_badge(e.action) %>
                  <span class={["badge badge-sm", class]}>{label}</span>
                </td>
                <td class="text-xs">{e.network}</td>
                <td class="text-xs font-mono">{e.class}</td>
                <td
                  class="text-xs font-mono max-w-[12rem] truncate"
                  title={format_identity_ref(e.network, e.identity_key)}
                >
                  {short_identity_ref(e.network, e.identity_key)}
                </td>
                <td class="text-xs opacity-70">{e.reason || "—"}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
