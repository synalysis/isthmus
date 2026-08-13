defmodule IsthmusWeb.Admin.TimelineLive do
  use IsthmusWeb, :live_view

  alias Isthmus.Audit

  @kinds Audit.kinds()

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(3_000, self(), :refresh)

    {:ok,
     socket
     |> assign(:page_title, "Timeline")
     |> assign(:selected_kinds, MapSet.new(@kinds))
     |> assign_data()}
  end

  @impl true
  def handle_event("toggle_kind", %{"kind" => kind}, socket) when kind in @kinds do
    selected = socket.assigns.selected_kinds

    selected =
      if MapSet.member?(selected, kind) do
        MapSet.delete(selected, kind)
      else
        MapSet.put(selected, kind)
      end

    {:noreply, socket |> assign(:selected_kinds, selected) |> assign_data()}
  end

  def handle_event("toggle_kind", _params, socket), do: {:noreply, socket}

  def handle_event("select_all_kinds", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_kinds, MapSet.new(@kinds))
     |> assign_data()}
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, assign_data(socket)}

  defp assign_data(socket) do
    kinds = MapSet.to_list(socket.assigns.selected_kinds)
    assign(socket, :entries, Audit.timeline(80, kinds: kinds))
  end

  defp kind_badge("governor"), do: {"governor", "badge-warning"}
  defp kind_badge("gateway"), do: {"gateway", "badge-info"}
  defp kind_badge("sighting"), do: {"sighting", "badge-success"}
  defp kind_badge(other), do: {other, "badge-ghost"}

  defp kind_label("governor"), do: "Governor"
  defp kind_label("gateway"), do: "Gateway"
  defp kind_label("sighting"), do: "Sighting"
  defp kind_label(other), do: other

  defp kind_filter_active_class("governor"), do: "btn-warning"
  defp kind_filter_active_class("gateway"), do: "btn-info"
  defp kind_filter_active_class("sighting"), do: "btn-success"
  defp kind_filter_active_class(_), do: "btn-neutral"

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :kinds, @kinds)

    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <section class="space-y-6">
        <.admin_header current={:timeline} title="Ops timeline">
          Unified view of announces, gateway forwards, and governor decisions.
        </.admin_header>

        <div id="timeline-filter" class="flex flex-wrap items-center gap-2">
          <span class="text-sm opacity-70">Kinds</span>
          <button
            :for={kind <- @kinds}
            type="button"
            id={"filter-#{kind}"}
            phx-click="toggle_kind"
            phx-value-kind={kind}
            class={[
              "btn btn-sm capitalize transition",
              if(MapSet.member?(@selected_kinds, kind),
                do: ["btn-active", kind_filter_active_class(kind)],
                else: "btn-ghost opacity-50"
              )
            ]}
          >
            {kind_label(kind)}
          </button>
          <button
            :if={MapSet.size(@selected_kinds) < length(@kinds)}
            type="button"
            id="filter-all-kinds"
            class="btn btn-ghost btn-xs"
            phx-click="select_all_kinds"
          >
            All
          </button>
          <span class="badge badge-ghost badge-sm ml-auto">{length(@entries)} shown</span>
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
                <td colspan="4" class="text-sm opacity-60">
                  <%= cond do %>
                    <% MapSet.size(@selected_kinds) == 0 -> %>
                      No kinds selected.
                    <% true -> %>
                      No recent activity.
                  <% end %>
                </td>
              </tr>
              <tr
                :for={e <- @entries}
                id={"timeline-#{e.kind}-#{e.id}"}
                data-kind={e.kind}
              >
                <td>
                  <.local_time id={"timeline-when-#{e.kind}-#{e.id}"} at={e.at} />
                </td>
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
