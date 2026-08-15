defmodule IsthmusWeb.Admin.MessagesLive do
  use IsthmusWeb, :live_view

  alias Isthmus.Messages

  @networks ~w(meshcore meshtastic reticulum nostr)
  @kinds ~w(channel group)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Isthmus.PubSub, "messages:heard")
    end

    {:ok,
     socket
     |> assign(:page_title, "Messages")
     |> assign(:selected_networks, MapSet.new(@networks))
     |> assign(:selected_kinds, MapSet.new(@kinds))
     |> assign(:filter_q, "")
     |> assign_rows()}
  end

  @impl true
  def handle_event("toggle_network", %{"network" => network}, socket)
      when network in @networks do
    selected = toggle_set(socket.assigns.selected_networks, network)
    {:noreply, socket |> assign(:selected_networks, selected) |> assign_rows()}
  end

  def handle_event("toggle_network", _params, socket), do: {:noreply, socket}

  def handle_event("select_all_networks", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_networks, MapSet.new(@networks))
     |> assign_rows()}
  end

  def handle_event("toggle_kind", %{"kind" => kind}, socket) when kind in @kinds do
    selected = toggle_set(socket.assigns.selected_kinds, kind)
    {:noreply, socket |> assign(:selected_kinds, selected) |> assign_rows()}
  end

  def handle_event("toggle_kind", _params, socket), do: {:noreply, socket}

  def handle_event("filter", %{"q" => q}, socket) do
    {:noreply, socket |> assign(:filter_q, to_string(q || "")) |> assign_rows()}
  end

  def handle_event("filter", _params, socket), do: {:noreply, socket}

  def handle_event("clear_filter", _params, socket) do
    {:noreply, socket |> assign(:filter_q, "") |> assign_rows()}
  end

  @impl true
  def handle_info({:heard_message, _}, socket), do: {:noreply, assign_rows(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp assign_rows(socket) do
    selected = socket.assigns.selected_networks
    kinds = socket.assigns.selected_kinds
    q = normalize_filter(socket.assigns.filter_q)

    raw =
      if MapSet.size(selected) == 0 or MapSet.size(kinds) == 0 do
        []
      else
        Messages.list_recent(200,
          networks: MapSet.to_list(selected),
          kinds: MapSet.to_list(kinds),
          per_network: true
        )
      end

    rows =
      raw
      |> Enum.map(fn m ->
        %{
          id: m.id,
          seen_at: m.seen_at,
          kind: m.kind,
          network: m.network,
          channel: channel_or_group_label(m),
          sender: m.sender_name || short_ref(m.network, m.from_ref),
          from_ref: m.from_ref,
          body: m.body
        }
      end)
      |> Enum.filter(&matches_filter?(&1, q))

    assign(socket, :rows, rows)
  end

  defp toggle_set(set, value) do
    if MapSet.member?(set, value), do: MapSet.delete(set, value), else: MapSet.put(set, value)
  end

  defp normalize_filter(q) when is_binary(q) do
    case String.trim(q) |> String.downcase() do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_filter(_), do: nil

  defp matches_filter?(_row, nil), do: true

  defp matches_filter?(row, q) do
    Enum.any?(
      [row.body, row.sender, row.channel, row.from_ref, row.network],
      fn v ->
        v
        |> to_string()
        |> String.downcase()
        |> String.contains?(q)
      end
    )
  end

  defp short_ref(_network, ref) when ref in [nil, ""], do: "—"
  defp short_ref(network, ref), do: short_identity_ref(network, ref)

  defp network_badge("meshcore"), do: "badge-secondary"
  defp network_badge("meshtastic"), do: "badge-warning"
  defp network_badge("reticulum"), do: "badge-info"
  defp network_badge("nostr"), do: "badge-accent"
  defp network_badge(_), do: "badge-ghost"

  defp network_label("meshcore"), do: "MeshCore"
  defp network_label("meshtastic"), do: "Meshtastic"
  defp network_label("reticulum"), do: "Reticulum"
  defp network_label("nostr"), do: "Nostr"
  defp network_label(other), do: other

  defp kind_label("channel"), do: "Channel"
  defp kind_label("group"), do: "Group"
  defp kind_label(other), do: other

  defp channel_or_group_label(m) do
    name = m.channel_name |> to_string() |> String.trim()

    cond do
      m.kind == "group" ->
        if name != "", do: name, else: "—"

      m.network == "meshtastic" and meshtastic_primary?(m) and
          generic_meshtastic_channel_name?(name) ->
        "Primary"

      name != "" ->
        name

      m.network == "meshcore" and m.channel_idx in [0, nil] ->
        "Public"

      is_integer(m.channel_idx) ->
        "slot #{m.channel_idx}"

      true ->
        "—"
    end
  end

  defp meshtastic_primary?(m), do: m.channel_idx in [0, nil]

  defp generic_meshtastic_channel_name?(""), do: true

  defp generic_meshtastic_channel_name?(name) do
    String.downcase(name) in ["channel", "primary", "primary channel"]
  end

  defp network_filter_active_class("meshcore"), do: "btn-secondary"
  defp network_filter_active_class("meshtastic"), do: "btn-warning"
  defp network_filter_active_class("reticulum"), do: "btn-info"
  defp network_filter_active_class("nostr"), do: "btn-accent"
  defp network_filter_active_class(_), do: "btn-neutral"

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :networks, @networks) |> assign(:kinds, @kinds)

    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <section class="space-y-6">
        <.admin_header current={:messages} title="Messages">
          Last Public channel text heard on MeshCore and Meshtastic, plus Isthmus
          group messages for groups that have retention on in <.link
            navigate={~p"/admin/registrations"}
            class="link"
          >Groups → Manage</.link>.
        </.admin_header>

        <p id="group-retention-off" class="text-sm opacity-70">
          Group bodies are discarded after forwarding unless that group has
          “Store messages” enabled.
        </p>

        <div id="messages-filter" class="flex flex-wrap items-center gap-2">
          <span class="text-sm opacity-70">Networks</span>
          <button
            :for={net <- @networks}
            type="button"
            id={"filter-#{net}"}
            phx-click="toggle_network"
            phx-value-network={net}
            class={[
              "btn btn-sm capitalize transition",
              if(MapSet.member?(@selected_networks, net),
                do: ["btn-active", network_filter_active_class(net)],
                else: "btn-ghost opacity-50"
              )
            ]}
          >
            {network_label(net)}
          </button>
          <button
            :if={MapSet.size(@selected_networks) < length(@networks)}
            type="button"
            id="filter-all-networks"
            class="btn btn-ghost btn-xs"
            phx-click="select_all_networks"
          >
            All
          </button>
          <span class="text-sm opacity-70 sm:ml-2">Kind</span>
          <button
            :for={kind <- @kinds}
            type="button"
            id={"filter-kind-#{kind}"}
            phx-click="toggle_kind"
            phx-value-kind={kind}
            class={[
              "btn btn-sm transition",
              if(MapSet.member?(@selected_kinds, kind),
                do: "btn-active btn-neutral",
                else: "btn-ghost opacity-50"
              )
            ]}
          >
            {kind_label(kind)}
          </button>
          <form
            id="messages-search-form"
            phx-change="filter"
            phx-submit="filter"
            class="flex min-w-[14rem] flex-1 items-center gap-2 sm:max-w-xs sm:flex-none sm:ml-auto [&_.fieldset]:mb-0"
          >
            <.input
              id="messages-search"
              name="q"
              type="search"
              value={@filter_q}
              placeholder="Filter sender or text"
              autocomplete="off"
              phx-debounce="200"
              class="w-full input input-sm"
            />
            <button
              :if={String.trim(@filter_q) != ""}
              type="button"
              id="messages-search-clear"
              class="btn btn-ghost btn-xs"
              phx-click="clear_filter"
            >
              Clear
            </button>
          </form>
          <span class="badge badge-ghost badge-sm">{length(@rows)} shown</span>
        </div>

        <div class="overflow-x-auto rounded-box border border-base-300" id="messages-table">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>When</th>
                <th>Network</th>
                <th>Kind</th>
                <th>Channel / group</th>
                <th>From</th>
                <th>Message</th>
              </tr>
            </thead>
            <tbody>
              <tr :if={@rows == []}>
                <td colspan="6" class="text-sm opacity-60">
                  <%= cond do %>
                    <% MapSet.size(@selected_networks) == 0 or MapSet.size(@selected_kinds) == 0 -> %>
                      Nothing selected.
                    <% String.trim(@filter_q) != "" -> %>
                      No messages match this filter.
                    <% true -> %>
                      No messages heard yet on the selected networks.
                  <% end %>
                </td>
              </tr>
              <tr
                :for={r <- @rows}
                id={"message-#{r.id}"}
                data-network={r.network}
                data-kind={r.kind}
                data-body={r.body}
              >
                <td>
                  <.local_time id={"message-when-#{r.id}"} at={r.seen_at} />
                </td>
                <td>
                  <span class={["badge badge-sm capitalize", network_badge(r.network)]}>
                    {r.network}
                  </span>
                </td>
                <td class="text-sm">{kind_label(r.kind)}</td>
                <td class="text-sm max-w-[10rem] truncate" title={r.channel}>{r.channel}</td>
                <td class="text-sm max-w-[10rem] truncate" title={r.from_ref || r.sender}>
                  {r.sender}
                </td>
                <td class="text-sm max-w-[28rem] truncate" title={r.body}>{r.body}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
