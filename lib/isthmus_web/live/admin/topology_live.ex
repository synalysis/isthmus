defmodule IsthmusWeb.Admin.TopologyLive do
  use IsthmusWeb, :live_view

  alias Isthmus.Topology

  @refresh_ms 10_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Isthmus.PubSub, "announce:sightings")
      Phoenix.PubSub.subscribe(Isthmus.PubSub, "tunnel:events")
      :timer.send_interval(@refresh_ms, self(), :refresh)
    end

    {:ok,
     socket
     |> assign(:page_title, "Topology")
     |> assign(:selected, nil)
     |> assign(:detail, nil)
     |> load_graph()}
  end

  @impl true
  def handle_event("topo_select", %{"id" => id}, socket) do
    detail = Topology.detail(socket.assigns.graph, id)

    {:noreply,
     socket
     |> assign(:selected, id)
     |> assign(:detail, detail)}
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, load_graph(socket)}
  def handle_info({:sighting, _}, socket), do: {:noreply, load_graph(socket)}
  def handle_info({:tunnel_sent, _}, socket), do: {:noreply, load_graph(socket)}
  def handle_info({:tunnel_control, _}, socket), do: {:noreply, load_graph(socket)}
  def handle_info({:tunnel_delivered, _}, socket), do: {:noreply, load_graph(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp load_graph(socket) do
    graph = Topology.build(:all)

    socket
    |> assign(:graph, graph)
    |> assign(:detail, refresh_detail(graph, socket.assigns.selected))
  end

  defp refresh_detail(_graph, nil), do: nil
  defp refresh_detail(graph, id), do: Topology.detail(graph, id)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <section class="space-y-6">
        <div class="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
          <div>
            <h1 class="text-3xl font-semibold">Topology</h1>
            <p class="mt-1 text-sm text-base-content/70">
              {@graph.counts.groups} groups · {@graph.counts.networks} networks · {@graph.counts.legs} legs · {@graph.counts.channels} channel slots · {@graph.counts.tunnels} tunnels.
              Click a node to inspect its identities.
            </p>
          </div>
          <.admin_nav current={:topology} />
        </div>

        <.topology_graph
          graph={@graph}
          selected={@selected}
          detail={@detail}
          manage_path={~p"/admin/registrations"}
        />
      </section>
    </Layouts.app>
    """
  end
end
