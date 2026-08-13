defmodule IsthmusWeb.Admin.AdvertsLive do
  use IsthmusWeb, :live_view

  alias Isthmus.Announce.KnownAddresses
  alias Isthmus.Announce.Sightings

  @networks ~w(meshcore reticulum nostr meshtastic)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Isthmus.PubSub, "announce:sightings")
      Phoenix.PubSub.subscribe(Isthmus.PubSub, "tunnel:events")
    end

    {:ok,
     socket
     |> assign(:page_title, "Adverts")
     |> assign(:selected_networks, MapSet.new(@networks))
     |> assign(:filter_q, "")
     |> assign_rows()}
  end

  @impl true
  def handle_event("toggle_network", %{"network" => network}, socket)
      when network in @networks do
    selected = socket.assigns.selected_networks

    selected =
      if MapSet.member?(selected, network) do
        MapSet.delete(selected, network)
      else
        MapSet.put(selected, network)
      end

    {:noreply, socket |> assign(:selected_networks, selected) |> assign_rows()}
  end

  def handle_event("toggle_network", _params, socket), do: {:noreply, socket}

  def handle_event("select_all_networks", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_networks, MapSet.new(@networks))
     |> assign_rows()}
  end

  def handle_event("filter", %{"q" => q}, socket) do
    {:noreply, socket |> assign(:filter_q, to_string(q || "")) |> assign_rows()}
  end

  def handle_event("filter", _params, socket), do: {:noreply, socket}

  def handle_event("clear_filter", _params, socket) do
    {:noreply, socket |> assign(:filter_q, "") |> assign_rows()}
  end

  def handle_event("refresh", _params, socket), do: {:noreply, assign_rows(socket)}

  @impl true
  def handle_info({:sighting, _}, socket), do: {:noreply, assign_rows(socket)}
  def handle_info({:tunnel_delivered, _}, socket), do: {:noreply, assign_rows(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp assign_rows(socket) do
    selected = socket.assigns.selected_networks
    q = normalize_filter(socket.assigns.filter_q)

    # Take up to 200 per selected network, then merge. A single shared window
    # lets chatty Reticulum crowd MeshCore out of both the table and text filter.
    raw =
      Sightings.list_recent(200,
        networks: MapSet.to_list(selected),
        per_network: true
      )

    # Build a {network, ref} → name index so nameless older rows still show a
    # name learned from a newer sighting or the companion contact table.
    names =
      Enum.reduce(raw, %{}, fn s, acc ->
        key = {s.network, s.identity_ref}

        case {Map.get(acc, key), meta_name(s)} do
          {existing, nil} -> Map.put(acc, key, existing)
          {nil, name} -> Map.put(acc, key, name)
          {existing, _} -> Map.put(acc, key, existing)
        end
      end)

    rows =
      raw
      |> Enum.map(fn s ->
        key = {s.network, s.identity_ref}
        name = Map.get(names, key) || KnownAddresses.name_for(s.network, s.identity_ref)

        %{
          id: s.id,
          seen_at: s.seen_at,
          network: s.network,
          direction: s.direction,
          ref: s.identity_ref,
          hops: s.hops,
          name: name,
          via: via_label(s.meta)
        }
      end)
      # One row per identity — repeated synthetic/tunnel sightings previously
      # shared the same DOM id and left ghost rows after LiveView morphs.
      |> dedupe_latest_per_identity()
      |> Enum.filter(&matches_filter?(&1, q))

    assign(socket, :rows, rows)
  end

  defp dedupe_latest_per_identity(rows) do
    rows
    |> Enum.reduce({[], MapSet.new()}, fn row, {acc, seen} ->
      key = {row.network, row.ref}

      if MapSet.member?(seen, key) do
        {acc, seen}
      else
        {[row | acc], MapSet.put(seen, key)}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
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
    name = row.name |> to_string() |> String.downcase()
    ref = row.ref |> to_string() |> String.downcase()
    display = format_identity_ref(row.network, row.ref) |> to_string() |> String.downcase()
    String.contains?(name, q) or String.contains?(ref, q) or String.contains?(display, q)
  end

  defp meta_name(%{meta: meta}) when is_map(meta) do
    case meta["name"] || meta["display_name"] do
      n when is_binary(n) and n != "" -> n
      _ -> nil
    end
  end

  defp meta_name(_), do: nil

  defp via_label(meta) when is_map(meta) do
    source = meta["source"] || meta[:source]
    peer = meta["peer"] || meta[:peer]

    peer =
      case peer do
        p when is_binary(p) and p != "" -> p
        _ -> nil
      end

    case source do
      "bridge_advert" -> "MC bridge"
      "tunnel_advert" -> if(peer, do: "Tunnel · #{peer}", else: "Tunnel")
      "tunnel_data" -> if(peer, do: "Tunnel · #{peer}", else: "Tunnel")
      "tunnel_ack" -> if(peer, do: "Tunnel · #{peer}", else: "Tunnel")
      "push_advert" -> "Companion"
      "synthetic_advert" -> "Synthetic"
      "self_advert" -> "Self"
      "contact" -> "Contact"
      "announce" -> "RNS"
      "node_db" -> "Node DB"
      "nodeinfo" -> "NodeInfo"
      other when is_binary(other) and other != "" -> other
      _ -> "—"
    end
  end

  defp via_label(_), do: "—"

  defp network_badge("meshcore"), do: "badge-secondary"
  defp network_badge("reticulum"), do: "badge-info"
  defp network_badge("nostr"), do: "badge-accent"
  defp network_badge("meshtastic"), do: "badge-warning"
  defp network_badge(_), do: "badge-ghost"

  defp network_label("meshcore"), do: "MeshCore"
  defp network_label("reticulum"), do: "Reticulum"
  defp network_label("nostr"), do: "Nostr"
  defp network_label("meshtastic"), do: "Meshtastic"
  defp network_label(other), do: other

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :networks, @networks)

    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <section class="space-y-6">
        <div class="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
          <div>
            <h1 class="text-3xl font-semibold">Adverts</h1>
            <p class="mt-1 text-sm text-base-content/70">
              Heard identities from the last 24 hours: MeshCore flood-adverts,
              Reticulum LXMF announces, Nostr, and Meshtastic NodeInfo (Meshtastic
              has no flood advert). These power address suggestions when attaching
              members on <.link navigate={~p"/admin/registrations"} class="link">Groups</.link>.
            </p>
          </div>
          <.admin_nav current={:adverts} />
        </div>

        <div id="adverts-filter" class="flex flex-wrap items-center gap-2">
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
          <form
            id="adverts-search-form"
            phx-change="filter"
            phx-submit="filter"
            class="flex min-w-[14rem] flex-1 items-center gap-2 sm:max-w-xs sm:flex-none sm:ml-auto [&_.fieldset]:mb-0"
          >
            <.input
              id="adverts-search"
              name="q"
              type="search"
              value={@filter_q}
              placeholder="Filter name or address"
              autocomplete="off"
              phx-debounce="200"
              class="w-full input input-sm"
            />
            <button
              :if={String.trim(@filter_q) != ""}
              type="button"
              id="adverts-search-clear"
              class="btn btn-ghost btn-xs"
              phx-click="clear_filter"
            >
              Clear
            </button>
          </form>
          <span class="badge badge-ghost badge-sm">{length(@rows)} shown</span>
        </div>

        <div class="overflow-x-auto rounded-box border border-base-300" id="adverts-table">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>When</th>
                <th>Network</th>
                <th>Dir</th>
                <th>Via</th>
                <th>Name</th>
                <th>Address</th>
                <th>Hops</th>
              </tr>
            </thead>
            <tbody>
              <tr :if={@rows == []}>
                <td colspan="7" class="text-sm opacity-60">
                  <%= cond do %>
                    <% MapSet.size(@selected_networks) == 0 -> %>
                      No networks selected.
                    <% String.trim(@filter_q) != "" -> %>
                      No adverts match this filter.
                    <% true -> %>
                      No adverts heard yet on the selected networks.
                  <% end %>
                </td>
              </tr>
              <tr
                :for={r <- @rows}
                id={"advert-#{r.id}"}
                data-network={r.network}
                data-ref={r.ref}
              >
                <td>
                  <.local_time id={"advert-when-#{r.id}"} at={r.seen_at} />
                </td>
                <td>
                  <span class={["badge badge-sm capitalize", network_badge(r.network)]}>
                    {r.network}
                  </span>
                </td>
                <td class="text-xs uppercase opacity-70">{r.direction}</td>
                <td class="text-xs opacity-80" title={r.via}>{r.via}</td>
                <td class="text-sm max-w-[10rem] truncate" title={r.name || ""}>
                  {r.name || "—"}
                </td>
                <td
                  class="font-mono text-xs break-all"
                  title={format_identity_ref(r.network, r.ref)}
                >
                  {short_identity_ref(r.network, r.ref)}
                </td>
                <td class="text-xs">{r.hops || "?"}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp network_filter_active_class("meshcore"), do: "btn-secondary"
  defp network_filter_active_class("reticulum"), do: "btn-info"
  defp network_filter_active_class("nostr"), do: "btn-accent"
  defp network_filter_active_class("meshtastic"), do: "btn-warning"
  defp network_filter_active_class(_), do: "btn-neutral"
end
