defmodule IsthmusWeb.Admin.AdvertsLive do
  use IsthmusWeb, :live_view

  alias Isthmus.Announce.KnownAddresses
  alias Isthmus.Announce.Sightings

  @networks ~w(all meshcore reticulum nostr)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Isthmus.PubSub, "announce:sightings")
      Phoenix.PubSub.subscribe(Isthmus.PubSub, "tunnel:events")
    end

    {:ok,
     socket
     |> assign(:page_title, "Adverts")
     |> assign(:network, "all")
     |> assign_rows()}
  end

  @impl true
  def handle_event("filter", %{"network" => network}, socket) when network in @networks do
    {:noreply, socket |> assign(:network, network) |> assign_rows()}
  end

  def handle_event("filter", _params, socket), do: {:noreply, socket}

  def handle_event("refresh", _params, socket), do: {:noreply, assign_rows(socket)}

  @impl true
  def handle_info({:sighting, _}, socket), do: {:noreply, assign_rows(socket)}
  def handle_info({:tunnel_delivered, _}, socket), do: {:noreply, assign_rows(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp assign_rows(socket) do
    raw =
      case socket.assigns.network do
        "all" -> Sightings.list_recent(200)
        network -> Sightings.recent_for_network(network, 200)
      end

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
      Enum.map(raw, fn s ->
        key = {s.network, s.identity_ref}
        name = Map.get(names, key) || KnownAddresses.name_for(s.network, s.identity_ref)

        %{
          seen_at: s.seen_at,
          network: s.network,
          direction: s.direction,
          ref: s.identity_ref,
          hops: s.hops,
          name: name
        }
      end)

    assign(socket, :rows, rows)
  end

  defp meta_name(%{meta: meta}) when is_map(meta) do
    case meta["name"] || meta["display_name"] do
      n when is_binary(n) and n != "" -> n
      _ -> nil
    end
  end

  defp meta_name(_), do: nil

  defp network_badge("meshcore"), do: "badge-secondary"
  defp network_badge("reticulum"), do: "badge-info"
  defp network_badge("nostr"), do: "badge-accent"
  defp network_badge(_), do: "badge-ghost"

  defp short_ref(ref) when is_binary(ref) and byte_size(ref) > 20 do
    String.slice(ref, 0, 10) <> "…" <> String.slice(ref, -6, 6)
  end

  defp short_ref(ref), do: to_string(ref)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <section class="space-y-6">
        <div class="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
          <div>
            <h1 class="text-3xl font-semibold">Adverts</h1>
            <p class="mt-1 text-sm text-base-content/70">
              Announces / adverts heard in the last 24 hours. These power the
              address suggestions when attaching members on <.link
                navigate={~p"/admin/registrations"}
                class="link"
              >Groups</.link>.
            </p>
          </div>
          <.admin_nav current={:adverts} />
        </div>

        <div class="flex flex-wrap items-center gap-2">
          <span class="text-sm opacity-70">Network</span>
          <form phx-change="filter" id="adverts-filter">
            <select name="network" class="select select-bordered select-sm">
              <option value="all" selected={@network == "all"}>All</option>
              <option value="meshcore" selected={@network == "meshcore"}>MeshCore</option>
              <option value="reticulum" selected={@network == "reticulum"}>Reticulum</option>
              <option value="nostr" selected={@network == "nostr"}>Nostr</option>
            </select>
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
                <th>Name</th>
                <th>Address</th>
                <th>Hops</th>
              </tr>
            </thead>
            <tbody>
              <tr :if={@rows == []}>
                <td colspan="6" class="text-sm opacity-60">
                  No adverts heard yet on this network.
                </td>
              </tr>
              <tr :for={r <- @rows} id={"advert-#{r.network}-#{r.ref}"}>
                <td class="whitespace-nowrap text-xs font-mono">{r.seen_at}</td>
                <td>
                  <span class={["badge badge-sm capitalize", network_badge(r.network)]}>
                    {r.network}
                  </span>
                </td>
                <td class="text-xs uppercase opacity-70">{r.direction}</td>
                <td class="text-sm">{r.name || "—"}</td>
                <td class="font-mono text-xs break-all" title={r.ref}>{short_ref(r.ref)}</td>
                <td class="text-xs">{r.hops || "?"}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
