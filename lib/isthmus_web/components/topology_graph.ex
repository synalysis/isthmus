defmodule IsthmusWeb.TopologyGraph do
  @moduledoc """
  Renders an `Isthmus.Topology` graph as inline SVG with a detail drawer.

  Interactivity is server-driven: nodes carry `phx-click="topo_select"` with a
  `phx-value-id`, and the parent LiveView sets `:selected` / `:detail`.
  """
  use Phoenix.Component

  import IsthmusWeb.CoreComponents, only: [format_identity_ref: 2, short_identity_ref: 2]

  use Phoenix.VerifiedRoutes,
    endpoint: IsthmusWeb.Endpoint,
    router: IsthmusWeb.Router,
    statics: IsthmusWeb.static_paths()

  # Sized so labels stay readable when the viewBox scales down to fit the
  # page (a 1220-wide graph in an ~800px column is ~0.65× — 22px → ~14px).
  @group_w 260
  @group_h 72
  @net_w 200
  @net_h 68
  @tunnel_w 220
  @tunnel_h 68

  attr :graph, :map, required: true
  attr :selected, :string, default: nil
  attr :detail, :map, default: nil
  attr :manage_path, :string, default: nil

  def topology_graph(assigns) do
    ~H"""
    <div class="grid gap-4 lg:grid-cols-[1fr_320px]">
      <div class="rounded-box border border-base-300 bg-base-200 p-3 space-y-3">
        <%= if @graph.nodes == [] do %>
          <div class="flex items-center justify-center py-16 text-sm opacity-60" id="topo-empty">
            No groups yet. Register or create a bridge group to see the map.
          </div>
        <% else %>
          <div class="overflow-x-auto">
            <svg
              id="topo-svg"
              viewBox={"0 0 #{@graph.width} #{@graph.height}"}
              width="100%"
              height={@graph.height}
              class="min-w-[800px] text-base-content"
              role="img"
              aria-label="Bridge topology graph"
            >
              <g stroke-linecap="round">
                <line
                  :for={edge <- @graph.edges}
                  x1={edge_x1(edge, @graph)}
                  y1={edge_y1(edge, @graph)}
                  x2={edge_x2(edge, @graph)}
                  y2={edge_y2(edge, @graph)}
                  stroke="currentColor"
                  stroke-width={edge_width(edge, @selected)}
                  stroke-dasharray={edge_dash(edge)}
                  class={[edge_text(edge), edge_dim(@selected, edge), edge_path_class(edge)]}
                />
              </g>

              <g>
                <text
                  :for={edge <- channel_edges(@graph)}
                  x={(edge_x1(edge, @graph) + edge_x2(edge, @graph)) / 2}
                  y={(edge_y1(edge, @graph) + edge_y2(edge, @graph)) / 2 - 5}
                  text-anchor="middle"
                  class={["fill-accent text-[16px] font-medium", edge_dim(@selected, edge)]}
                >
                  {edge.ref}
                </text>
              </g>

              <g :for={node <- @graph.nodes}>
                <.node_shape node={node} selected={@selected} />
              </g>
            </svg>
          </div>

          <div class="flex flex-wrap items-center gap-x-4 gap-y-1 text-sm" id="topo-legend">
            <span
              :for={item <- @graph.legend}
              class="inline-flex items-center gap-1.5"
            >
              <span class={["inline-block h-2.5 w-2.5 rounded-full", role_bg(item.key)]}></span>
              {item.label}
            </span>
          </div>
        <% end %>
      </div>

      <aside class="rounded-box border border-base-300 bg-base-200 p-4" id="topo-detail">
        <%= if @detail do %>
          <.detail_panel detail={@detail} manage_path={@manage_path} />
        <% else %>
          <div class="text-sm opacity-60">
            Select a group or network node to inspect its identities.
          </div>
        <% end %>
      </aside>
    </div>
    """
  end

  attr :node, :map, required: true
  attr :selected, :boolean, default: nil

  defp node_shape(%{node: %{kind: :group}} = assigns) do
    assigns =
      assigns
      |> assign(:w, @group_w)
      |> assign(:h, @group_h)
      |> assign(:bridge?, assigns.node.meta.kind == "bridge")

    ~H"""
    <g phx-click="topo_select" phx-value-id={@node.id} class="cursor-pointer">
      <rect
        x={@node.x - @w / 2}
        y={@node.y - @h / 2}
        width={@w}
        height={@h}
        rx="10"
        fill="var(--color-base-100, #fff)"
        stroke="currentColor"
        stroke-width={if @selected == @node.id, do: "3", else: "1.5"}
        stroke-dasharray={if @bridge?, do: "6 4", else: nil}
        class={if @selected == @node.id, do: "text-primary", else: "text-base-content/40"}
      />
      <text
        x={@node.x}
        y={@node.y - 4}
        text-anchor="middle"
        class="fill-base-content text-[24px] font-semibold"
      >
        {truncate(@node.label, 22)}
      </text>
      <text
        x={@node.x}
        y={@node.y + 22}
        text-anchor="middle"
        class="fill-base-content/70 text-[17px]"
      >
        {@node.meta.kind}{channel_suffix(@node.meta.channel_idx)}
      </text>
    </g>
    """
  end

  defp node_shape(%{node: %{kind: :network}} = assigns) do
    assigns =
      assigns
      |> assign(:w, @net_w)
      |> assign(:h, @net_h)

    ~H"""
    <g phx-click="topo_select" phx-value-id={@node.id} class="cursor-pointer">
      <rect
        x={@node.x - @w / 2}
        y={@node.y - @h / 2}
        width={@w}
        height={@h}
        rx="10"
        fill="var(--color-base-300, #e5e7eb)"
        stroke="currentColor"
        stroke-width={if @selected == @node.id, do: "3", else: "1.5"}
        class={if @selected == @node.id, do: "text-primary", else: "text-accent"}
      />
      <text
        x={@node.x}
        y={@node.y + 7}
        text-anchor="middle"
        class="fill-base-content text-[24px] font-semibold"
      >
        {@node.label}
      </text>
      <circle
        :if={severity_class(@node.meta.severity)}
        cx={@node.x + @w / 2 - 10}
        cy={@node.y - @h / 2 + 10}
        r="5"
        stroke="var(--color-base-100, #fff)"
        stroke-width="1.5"
        fill="currentColor"
        class={severity_class(@node.meta.severity)}
      >
        <title>{@node.meta.severity}</title>
      </circle>
    </g>
    """
  end

  defp node_shape(%{node: %{kind: :tunnel}} = assigns) do
    assigns =
      assigns
      |> assign(:w, @tunnel_w)
      |> assign(:h, @tunnel_h)

    ~H"""
    <g phx-click="topo_select" phx-value-id={@node.id} class="cursor-pointer">
      <rect
        x={@node.x - @w / 2}
        y={@node.y - @h / 2}
        width={@w}
        height={@h}
        rx="6"
        fill="var(--color-base-100, #fff)"
        stroke="currentColor"
        stroke-width={if @selected == @node.id, do: "3", else: "1.5"}
        stroke-dasharray={unless @node.meta.enabled, do: "5 4", else: nil}
        class={[
          if(@selected == @node.id, do: "text-primary", else: "text-info"),
          unless(@node.meta.enabled, do: "opacity-60")
        ]}
      />
      <text
        x={@node.x}
        y={@node.y - 4}
        text-anchor="middle"
        class="fill-base-content text-[24px] font-semibold"
      >
        {truncate(@node.label, 18)}
      </text>
      <text
        x={@node.x}
        y={@node.y + 22}
        text-anchor="middle"
        class="fill-base-content/70 text-[16px]"
      >
        tunnel{unless @node.meta.enabled, do: " · off"}
      </text>
    </g>
    """
  end

  attr :detail, :map, required: true
  attr :manage_path, :string, default: nil

  defp detail_panel(assigns) do
    ~H"""
    <div class="space-y-3">
      <div>
        <h3 class="text-lg font-semibold leading-tight">{@detail.title}</h3>
        <p class="text-xs opacity-60">{@detail.subtitle}</p>
      </div>

      <%= if @detail.kind == :group do %>
        <dl class="grid grid-cols-3 gap-x-2 gap-y-1 text-xs">
          <dt class="opacity-60">Status</dt>
          <dd class="col-span-2 font-mono">{@detail.status}</dd>
          <dt :if={@detail.slug not in [nil, ""]} class="opacity-60">Slug</dt>
          <dd :if={@detail.slug not in [nil, ""]} class="col-span-2 font-mono">
            @{@detail.slug}
          </dd>
          <dt :if={@detail.channel_idx} class="opacity-60">MC slot</dt>
          <dd :if={@detail.channel_idx} class="col-span-2 font-mono">{@detail.channel_idx}</dd>
        </dl>
      <% end %>

      <%= if @detail.kind == :network and @detail.severity do %>
        <div class="flex items-center gap-2 text-xs">
          <span class={["inline-block h-2.5 w-2.5 rounded-full", severity_bg(@detail.severity)]}></span>
          <span class="opacity-70">Health: {@detail.severity}</span>
        </div>
      <% end %>

      <%= if @detail.kind == :network and @detail[:bridged?] do %>
        <p class="text-xs opacity-70">
          Bridged island — a repeater feeds this network's raw packets across the tunnel,
          so remote nodes appear as ordinary mesh neighbours.
        </p>
      <% end %>

      <%= if @detail.kind == :tunnel do %>
        <dl class="grid grid-cols-3 gap-x-2 gap-y-1 text-xs">
          <dt class="opacity-60">Enabled</dt>
          <dd class="col-span-2 font-mono">{@detail.enabled}</dd>
          <dt class="opacity-60">Tunnel</dt>
          <dd class="col-span-2 font-mono break-all">{@detail.tunnel_id}</dd>
          <dt class="opacity-60">Peer</dt>
          <dd
            class="col-span-2 font-mono"
            title={format_identity_ref(@detail.carrier_network, @detail.peer_ref)}
          >
            {short_identity_ref(@detail.carrier_network, @detail.peer_ref)}
          </dd>
          <dt class="opacity-60">Seq</dt>
          <dd class="col-span-2 font-mono">{@detail.seq}</dd>
          <dt :if={@detail.sighting} class="opacity-60">Last seen</dt>
          <dd :if={@detail.sighting} class="col-span-2 font-mono">
            {sighting_line(@detail.sighting)}
          </dd>
        </dl>
      <% end %>

      <div :if={@detail.legs != []} class="space-y-1.5">
        <p class="text-xs uppercase tracking-wide opacity-50">Legs</p>
        <ul class="space-y-1">
          <li
            :for={leg <- @detail.legs}
            class="flex items-center justify-between gap-2 rounded-lg bg-base-300/50 px-2 py-1.5 text-xs"
          >
            <span class="inline-flex items-center gap-1.5">
              <span class={["inline-block h-2 w-2 rounded-full", role_bg(leg.role)]}></span>
              <span :if={Map.get(leg, :network)} class="capitalize">{leg.network}</span>
              <span class="opacity-60">{leg.role}</span>
            </span>
            <code
              class="font-mono opacity-70"
              title={format_identity_ref(Map.get(leg, :network), leg.ref)}
            >
              {short_identity_ref(Map.get(leg, :network), leg.ref)}
            </code>
          </li>
        </ul>
      </div>

      <.link
        :if={@manage_path}
        navigate={@manage_path}
        class="link link-hover text-sm inline-block"
      >
        Manage groups →
      </.link>
    </div>
    """
  end

  # --- geometry ---------------------------------------------------------------
  # Endpoints connect the node sides that face each other, so the same helper
  # works for group->network (left column) and tunnel->network (right column).

  defp edge_x1(edge, graph) do
    from = find_node(graph, edge.from)
    to = find_node(graph, edge.to)
    node_face_x(from, facing_side(from, to))
  end

  defp edge_x2(edge, graph) do
    from = find_node(graph, edge.from)
    to = find_node(graph, edge.to)
    node_face_x(to, facing_side(to, from))
  end

  defp edge_y1(edge, graph), do: node_y(graph, edge.from) + Map.get(edge, :offset, 0)
  defp edge_y2(edge, graph), do: node_y(graph, edge.to) + Map.get(edge, :offset, 0)

  defp facing_side(%{x: ax}, %{x: bx}) when ax <= bx, do: :right
  defp facing_side(_, _), do: :left

  defp node_face_x(%{kind: kind, x: x}, side) do
    half = node_half_w(kind)
    if side == :right, do: x + half, else: x - half
  end

  defp node_face_x(_, _), do: 0

  defp node_half_w(:group), do: @group_w / 2
  defp node_half_w(:network), do: @net_w / 2
  defp node_half_w(:tunnel), do: @tunnel_w / 2
  defp node_half_w(_), do: 0

  defp node_y(graph, id) do
    case find_node(graph, id) do
      %{y: y} -> y
      _ -> 0
    end
  end

  defp find_node(%{nodes: nodes}, id), do: Enum.find(nodes, &(&1.id == id))

  # --- styling ----------------------------------------------------------------

  defp edge_text(%{type: :tunnel, leg: :payload}), do: "text-info"
  defp edge_text(%{type: :tunnel, leg: :carrier}), do: "text-base-content/40"
  defp edge_text(%{type: :channel}), do: "text-accent"
  defp edge_text(%{role: role}), do: role_text(role)

  defp channel_edges(%{edges: edges}), do: Enum.filter(edges, &(&1.type == :channel))

  # Channel slots are broadcast group chat rather than a point-to-point identity,
  # so they read as a dotted line instead of the dashed "external" legs.
  defp edge_dash(%{type: :channel}), do: "2 4"
  defp edge_dash(%{dashed?: true}), do: "5 4"
  defp edge_dash(_), do: nil

  defp edge_width(edge, selected) do
    cond do
      selected in [edge.from, edge.to] -> "2.5"
      Map.get(edge, :recent?) -> "2.5"
      true -> "1.5"
    end
  end

  # External Reticulum legs with a known path get a slight emphasis; unknown/
  # unavailable paths are dimmed so operators can spot unreachable peers.
  defp edge_path_class(%{path_state: :known}), do: nil
  defp edge_path_class(%{path_state: :unknown}), do: "opacity-40"
  defp edge_path_class(%{path_state: :unavailable}), do: "opacity-40"
  defp edge_path_class(_), do: nil

  defp severity_class(:ok), do: "text-success"
  defp severity_class(:info), do: "text-info"
  defp severity_class(:warn), do: "text-warning"
  defp severity_class(:error), do: "text-error"
  defp severity_class(_), do: nil

  defp severity_bg(:ok), do: "bg-success"
  defp severity_bg(:info), do: "bg-info"
  defp severity_bg(:warn), do: "bg-warning"
  defp severity_bg(:error), do: "bg-error"
  defp severity_bg(_), do: "bg-base-content/40"

  defp sighting_line(%{hops: hops, latency_ms: latency}) do
    [hops && "#{hops} hop(s)", latency && "#{latency} ms"]
    |> Enum.reject(&(&1 in [nil, false]))
    |> case do
      [] -> "seen"
      parts -> Enum.join(parts, " · ")
    end
  end

  defp sighting_line(_), do: "seen"

  defp role_text("primary"), do: "text-primary"
  defp role_text("member"), do: "text-secondary"
  defp role_text("proxy"), do: "text-base-content/40"
  defp role_text(_), do: "text-base-content/40"

  defp role_bg("primary"), do: "bg-primary"
  defp role_bg("member"), do: "bg-secondary"
  defp role_bg("proxy"), do: "bg-base-content/40"
  defp role_bg("channel"), do: "bg-accent"
  defp role_bg("payload"), do: "bg-info"
  defp role_bg("carrier"), do: "bg-base-content/40"
  defp role_bg(_), do: "bg-base-content/40"

  defp edge_dim(nil, _edge), do: nil

  defp edge_dim(selected, edge) do
    if selected in [edge.from, edge.to], do: nil, else: "opacity-30"
  end

  defp channel_suffix(nil), do: ""
  defp channel_suffix(idx), do: " · ch #{idx}"

  defp truncate(nil, _), do: ""

  defp truncate(text, max) when is_binary(text) do
    if String.length(text) > max, do: String.slice(text, 0, max - 1) <> "…", else: text
  end

end
