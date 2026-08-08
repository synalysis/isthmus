defmodule IsthmusWeb.MeLive do
  use IsthmusWeb, :live_view

  alias Isthmus.Networks.Reticulum
  alias Isthmus.QR
  alias Isthmus.Registrations
  alias Isthmus.Topology

  @path_refresh_ms 5_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(@path_refresh_ms, self(), :refresh_paths)
      Phoenix.PubSub.subscribe(Isthmus.PubSub, "announce:sightings")
      Phoenix.PubSub.subscribe(Isthmus.PubSub, "tunnel:events")
    end

    {:ok,
     socket
     |> assign(:page_title, "My identities")
     |> assign(:path_by_leg, %{})
     |> assign(:selected, nil)
     |> assign(:detail, nil)
     |> load_groups()}
  end

  @impl true
  def handle_info(:refresh_paths, socket) do
    {:noreply, socket |> assign_path_status() |> assign_graph()}
  end

  def handle_info({:sighting, _}, socket), do: {:noreply, assign_graph(socket)}
  def handle_info({:tunnel_sent, _}, socket), do: {:noreply, assign_graph(socket)}
  def handle_info({:tunnel_control, _}, socket), do: {:noreply, assign_graph(socket)}
  def handle_info({:tunnel_delivered, _}, socket), do: {:noreply, assign_graph(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("topo_select", %{"id" => id}, socket) do
    detail = Topology.detail(socket.assigns.graph, id)

    {:noreply,
     socket
     |> assign(:selected, id)
     |> assign(:detail, detail)}
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    group = Registrations.get_group!(id)

    if group.owner_pubkey_hex == socket.assigns.current_user.pubkey_hex do
      {:ok, _} = Registrations.revoke(group)

      {:noreply,
       socket
       |> put_flash(:info, "Registration revoked.")
       |> load_groups()}
    else
      {:noreply, put_flash(socket, :error, "Not allowed.")}
    end
  end

  def handle_event("announce_leg", %{"leg_id" => leg_id, "group_id" => group_id}, socket) do
    group = Registrations.get_group!(group_id)

    if group.owner_pubkey_hex != socket.assigns.current_user.pubkey_hex do
      {:noreply, put_flash(socket, :error, "Not allowed.")}
    else
      leg = Enum.find(group.legs, &(&1.id == leg_id))

      case leg && Registrations.announce_leg(leg) do
        :ok ->
          {:noreply, put_flash(socket, :info, "Announced on #{leg.network}.")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Announce failed: #{format_reason(reason)}")}

        nil ->
          {:noreply, put_flash(socket, :error, "Leg not found.")}
      end
    end
  end

  def handle_event("request_path", %{"leg_id" => leg_id, "group_id" => group_id}, socket) do
    group = Registrations.get_group!(group_id)

    if group.owner_pubkey_hex != socket.assigns.current_user.pubkey_hex do
      {:noreply, put_flash(socket, :error, "Not allowed.")}
    else
      leg = Enum.find(group.legs, &(&1.id == leg_id))

      case leg && Registrations.request_reticulum_path(leg) do
        {:ok, status} ->
          socket = put_path_status(socket, leg.id, status)

          flash =
            if status.path_known or status.identity_known do
              "Path known for #{short_ref(leg.identity_ref)}."
            else
              "Path request sent for #{short_ref(leg.identity_ref)}. Waiting for peer announce…"
            end

          {:noreply, put_flash(socket, :info, flash)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Path request failed: #{format_reason(reason)}")}

        nil ->
          {:noreply, put_flash(socket, :error, "Leg not found.")}
      end
    end
  end

  def handle_event("announce_all", %{"id" => id}, socket) do
    group = Registrations.get_group!(id)

    if group.owner_pubkey_hex != socket.assigns.current_user.pubkey_hex do
      {:noreply, put_flash(socket, :error, "Not allowed.")}
    else
      case Registrations.announce_group(group) do
        {:ok, results} ->
          {:noreply,
           socket
           |> put_flash(:info, summarize_announce_results(results))
           |> load_groups()}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Announce failed: #{format_reason(reason)}")}
      end
    end
  end

  def handle_event("ensure_bridge_proxy", %{"id" => id}, socket) do
    group = Registrations.get_group!(id)

    if group.owner_pubkey_hex != socket.assigns.current_user.pubkey_hex do
      {:noreply, put_flash(socket, :error, "Not allowed.")}
    else
      case Registrations.ensure_bridge_rns_proxy(group) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(
             :info,
             "Bridge RNS proxy ready — announce that proxy, not attached members."
           )
           |> load_groups()}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Could not mint proxy: #{format_reason(reason)}")}
      end
    end
  end

  def handle_event("ensure_nostr_proxy", %{"id" => id}, socket) do
    group = Registrations.get_group!(id)

    if group.owner_pubkey_hex != socket.assigns.current_user.pubkey_hex do
      {:noreply, put_flash(socket, :error, "Not allowed.")}
    else
      case Registrations.ensure_nostr_proxy(group) do
        {:ok, _} ->
          {:noreply,
           socket
           |> put_flash(
             :info,
             "Nostr proxy ready — KeyChat should DM that npub (replies route by recipient)."
           )
           |> load_groups()}

        {:error, reason} ->
          {:noreply,
           put_flash(socket, :error, "Could not mint Nostr proxy: #{format_reason(reason)}")}
      end
    end
  end

  defp load_groups(socket) do
    groups = Registrations.get_for_owner(socket.assigns.current_user.pubkey_hex)

    socket
    |> assign(:groups, groups)
    |> assign_path_status()
    |> assign_graph()
  end

  defp assign_graph(socket) do
    graph =
      Topology.build({:owner, socket.assigns.current_user.pubkey_hex},
        path_by_leg: socket.assigns.path_by_leg
      )

    socket
    |> assign(:graph, graph)
    |> assign(:detail, refresh_detail(graph, socket.assigns[:selected]))
  end

  defp refresh_detail(_graph, nil), do: nil
  defp refresh_detail(graph, id), do: Topology.detail(graph, id)

  defp assign_path_status(socket) do
    groups = socket.assigns[:groups] || []

    status =
      groups
      |> Enum.flat_map(& &1.legs)
      |> Enum.filter(&Registrations.external_reticulum_leg?/1)
      |> Enum.reduce(%{}, fn leg, acc ->
        case Reticulum.path_status(leg.identity_ref) do
          {:ok, status} -> Map.put(acc, leg.id, status)
          {:error, reason} -> Map.put(acc, leg.id, %{error: reason, path_known: false})
        end
      end)

    assign(socket, :path_by_leg, status)
  end

  defp put_path_status(socket, leg_id, status) do
    assign(socket, :path_by_leg, Map.put(socket.assigns.path_by_leg, leg_id, status))
  end

  defp path_badge(path_by_leg, leg) do
    case Map.get(path_by_leg, leg.id) do
      %{path_known: true} -> {"path known", "badge-success"}
      %{identity_known: true} -> {"keys known", "badge-success"}
      %{error: _} -> {"path unavailable", "badge-warning"}
      %{} -> {"path unknown", "badge-ghost"}
      nil -> {"path …", "badge-ghost"}
    end
  end

  defp short_ref(ref) when is_binary(ref) and byte_size(ref) > 12 do
    String.slice(ref, 0, 8) <> "…"
  end

  defp short_ref(ref), do: ref

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <section class="space-y-8">
        <div class="flex flex-wrap items-end justify-between gap-4">
          <div>
            <h1 class="text-3xl font-semibold">My identities</h1>
            <p class="mt-2 font-mono text-sm break-all text-base-content/70">{@current_user.npub}</p>
          </div>
          <.link navigate={~p"/register"} class="btn btn-outline btn-sm">Register</.link>
        </div>

        <div :if={@groups != []} class="space-y-2">
          <h2 class="text-xl font-medium">My network map</h2>
          <.topology_graph graph={@graph} selected={@selected} detail={@detail} />
        </div>

        <%= if @groups == [] do %>
          <div class="alert">
            No groups yet. <.link navigate={~p"/register"} class="link">Register</.link>
            or ask an admin to attach you to a bridge group.
          </div>
        <% else %>
          <div :for={group <- @groups} class="space-y-4">
            <div class="flex flex-wrap items-center justify-between gap-2">
              <div>
                <h2 class="text-xl font-medium">
                  {group.display_name || "Group"}
                  <span class={[
                    "badge badge-sm ml-2",
                    group.kind == "bridge" && "badge-secondary",
                    group.kind != "bridge" && "badge-ghost"
                  ]}>
                    {group.kind || "registration"}
                  </span>
                </h2>
                <p :if={group.status == "active"} class="text-sm opacity-70 mt-1">
                  MeshCore address:
                  <code class="font-mono">@{Registrations.token_slug(group.display_name)}</code>
                  — prefix DMs to the companion with this token when multiple groups are active.
                </p>
                <p :if={group.meshcore_channel_idx != nil} class="text-sm opacity-70 mt-1">
                  MeshCore channel slot <span class="font-mono">{group.meshcore_channel_idx}</span>
                  — group chat on the radio bridges to attached members.
                </p>
              </div>
              <div class="flex flex-wrap gap-2">
                <button
                  :if={
                    group.status == "active" and group.kind == "bridge" and
                      not Enum.any?(group.legs, &(&1.network == "reticulum" and &1.role == "proxy"))
                  }
                  class="btn btn-secondary btn-sm"
                  phx-click="ensure_bridge_proxy"
                  phx-value-id={group.id}
                >
                  Mint RNS proxy
                </button>
                <button
                  :if={
                    group.status == "active" and
                      not Enum.any?(group.legs, &(&1.network == "nostr" and &1.role == "proxy"))
                  }
                  class="btn btn-secondary btn-sm"
                  phx-click="ensure_nostr_proxy"
                  phx-value-id={group.id}
                >
                  Mint Nostr proxy
                </button>
                <button
                  :if={group.status == "active" and announceable?(group)}
                  class="btn btn-outline btn-sm"
                  phx-click="announce_all"
                  phx-value-id={group.id}
                >
                  Announce all
                </button>
                <button
                  class="btn btn-ghost btn-sm text-error"
                  phx-click="revoke"
                  phx-value-id={group.id}
                  data-confirm="Revoke this group?"
                >
                  Revoke
                </button>
              </div>
            </div>

            <div class="grid gap-4 md:grid-cols-3">
              <div :for={leg <- group.legs} class="card bg-base-200 border border-base-300">
                <div class="card-body space-y-3">
                  <div class="flex items-start justify-between gap-2">
                    <h3 class="card-title capitalize">
                      {leg.network} <span class="badge badge-sm">{leg.role}</span>
                      <%= if Registrations.external_reticulum_leg?(leg) do %>
                        <% {label, class} = path_badge(@path_by_leg, leg) %>
                        <span
                          id={"rns-path-#{leg.id}"}
                          class={["badge badge-sm", class]}
                        >
                          {label}
                        </span>
                      <% end %>
                    </h3>
                    <div class="flex flex-wrap gap-1 justify-end">
                      <button
                        :if={group.status == "active" and Registrations.can_announce_leg?(leg)}
                        class="btn btn-outline btn-xs"
                        phx-click="announce_leg"
                        phx-value-leg_id={leg.id}
                        phx-value-group_id={group.id}
                        title={announce_hint(leg.network)}
                      >
                        Announce
                      </button>
                      <button
                        :if={group.status == "active" and Registrations.external_reticulum_leg?(leg)}
                        class="btn btn-ghost btn-xs"
                        phx-click="request_path"
                        phx-value-leg_id={leg.id}
                        phx-value-group_id={group.id}
                        title="Ask the mesh for a path to this external destination"
                      >
                        Request path
                      </button>
                    </div>
                  </div>
                  <%= for item <- presentation_items(leg) do %>
                    <div class="space-y-2">
                      <p class="text-sm font-medium">{item["label"] || item[:label]}</p>
                      <p class="font-mono text-xs break-all">
                        {item["uri_or_text"] || item[:uri_or_text]}
                      </p>
                      <%= if qr = qr_svg(item) do %>
                        <div class="bg-white p-2 rounded-lg inline-block">
                          {Phoenix.HTML.raw(qr)}
                        </div>
                      <% end %>
                      <p class="text-xs opacity-60">
                        {(item["app_hints"] || item[:app_hints] || []) |> Enum.join(" · ")}
                      </p>
                    </div>
                  <% end %>
                  <p :if={Registrations.can_announce_leg?(leg)} class="text-xs opacity-50">
                    {announce_hint(leg.network)}
                  </p>
                  <p :if={Registrations.external_reticulum_leg?(leg)} class="text-xs opacity-50">
                    External peer — announce from MeshChatX/Sideband. Badge refreshes every 5s;
                    Request path asks the mesh for a route.
                  </p>
                </div>
              </div>
            </div>
          </div>
        <% end %>
      </section>
    </Layouts.app>
    """
  end

  defp presentation_items(leg) do
    case leg.presentation_cache do
      %{"items" => items} when is_list(items) -> items
      %{items: items} when is_list(items) -> items
      _ -> []
    end
  end

  defp qr_svg(item) do
    payload = item["qr_payload"] || item[:qr_payload]
    QR.svg(payload)
  end

  defp announceable?(%{legs: legs}) when is_list(legs) do
    Enum.any?(legs, &Registrations.can_announce_leg?/1)
  end

  defp announceable?(_), do: false

  defp announce_hint("reticulum"),
    do: "Sends an LXMF path announce for this Isthmus-owned destination."

  defp announce_hint(:reticulum), do: announce_hint("reticulum")

  defp announce_hint("meshcore"),
    do: "Sends a companion self-advert on the connected MeshCore radio (zero-hop)."

  defp announce_hint(:meshcore), do: announce_hint("meshcore")
  defp announce_hint(_), do: "Send a discovery announce on this network."

  defp summarize_announce_results(results) do
    parts =
      Enum.map(results, fn {net, result} ->
        case result do
          :ok -> "#{net}: ok"
          {:error, reason} -> "#{net}: #{format_reason(reason)}"
        end
      end)

    "Announce results — " <> Enum.join(parts, "; ")
  end

  defp format_reason({:governor, reason}), do: "rate-limited (#{reason})"

  defp format_reason("unknown_destination"),
    do:
      "destination not registered in the sidecar (proxy keys missing — remint/register and retry)"

  defp format_reason(:unknown_destination), do: format_reason("unknown_destination")

  defp format_reason(:external_identity),
    do:
      "cannot announce an attached/external identity — announce the bridge RNS proxy, or Request path to the peer"

  defp format_reason(:no_announceable_legs),
    do: "no Isthmus-owned proxy legs to announce (mint an RNS proxy for bridge groups)"

  defp format_reason(:rns_not_live), do: "RNS sidecar is not live"

  defp format_reason(:rns_still_stub),
    do: "RNS sidecar still minting stubs — check python rns/lxmf"

  defp format_reason(:stub_material), do: "stored RNS key is a stub; remint failed"
  defp format_reason(reason) when is_atom(reason), do: to_string(reason)
  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
