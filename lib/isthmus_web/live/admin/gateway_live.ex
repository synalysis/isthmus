defmodule IsthmusWeb.Admin.GatewayLive do
  use IsthmusWeb, :live_view

  alias Isthmus.Gateway
  alias Isthmus.Nostr.Bech32
  alias Isthmus.Nostr.Crypto

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(3_000, self(), :refresh)

    {:ok,
     socket
     |> assign(:page_title, "Gateway")
     |> assign_data()}
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, assign_data(socket)}

  defp assign_data(socket) do
    service =
      case Crypto.service_keypair() do
        {:ok, _, pk} -> Bech32.encode_npub(pk)
        _ -> nil
      end

    stats = Gateway.stats()

    socket
    |> assign(:entries, Gateway.list_forward_log(50))
    |> assign(:dead, Gateway.list_dead(30))
    |> assign(:stats, stats)
    |> assign(:service_npub, service)
  end

  defp status_badge("delivered"), do: {"delivered", "badge-success"}
  defp status_badge("failed"), do: {"failed", "badge-error"}
  defp status_badge("retained"), do: {"retained", "badge-info"}
  defp status_badge("dropped"), do: {"dropped", "badge-warning"}
  defp status_badge(other), do: {other || "unknown", "badge-ghost"}

  defp status_count(stats, key) do
    Map.get(stats.by_status_24h, key, 0)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <section class="space-y-6">
        <div class="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
          <div>
            <h1 class="text-3xl font-semibold">Gateway</h1>
            <p class="mt-1 text-sm text-base-content/70">
              Forward stats and route log (message content is never shown).
            </p>
          </div>
          <.admin_nav current={:gateway} />
        </div>

        <div class="alert alert-info text-sm">
          <%= if @service_npub do %>
            Nostr node identity: <span class="font-mono">{@service_npub}</span>
            — tunnel carrier on Nostr. Group DMs use each group’s proxy npub (see Groups / MeshCore).
          <% else %>
            Set <code>ISTHMUS_NOSTR_NSEC</code> for the Nostr tunnel carrier identity.
          <% end %>
        </div>

        <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          <div class="stat bg-base-200 rounded-box border border-base-300 py-3">
            <div class="stat-title">Last hour</div>
            <div class="stat-value text-2xl">{@stats.last_hour}</div>
            <div class="stat-desc">forward attempts</div>
          </div>
          <div class="stat bg-base-200 rounded-box border border-base-300 py-3">
            <div class="stat-title">Last 24h</div>
            <div class="stat-value text-2xl">{@stats.last_24h}</div>
            <div class="stat-desc">
              {status_count(@stats, "delivered")} delivered · {status_count(@stats, "failed")} failed · {status_count(
                @stats,
                "dropped"
              )} dropped
            </div>
          </div>
          <div class="stat bg-base-200 rounded-box border border-base-300 py-3">
            <div class="stat-title">Delivered (24h)</div>
            <div class="stat-value text-2xl text-success">{status_count(@stats, "delivered")}</div>
            <div class="stat-desc">
              all-time delivered: {Map.get(@stats.by_status, "delivered", 0)}
            </div>
          </div>
          <div class="stat bg-base-200 rounded-box border border-base-300 py-3">
            <div class="stat-title">Total logged</div>
            <div class="stat-value text-2xl">{@stats.total}</div>
            <div class="stat-desc">all statuses</div>
          </div>
        </div>

        <div :if={@stats.by_route_24h != []} class="space-y-2">
          <h2 class="text-lg font-medium">Routes (24h)</h2>
          <div class="flex flex-wrap gap-2">
            <span
              :for={r <- @stats.by_route_24h}
              class="badge badge-outline badge-lg gap-1 font-mono"
            >
              {r.from} → {r.to}
              <span class="opacity-70">{r.count}</span>
            </span>
          </div>
        </div>

        <div :if={@dead != []} class="space-y-2">
          <h2 class="text-lg font-medium">Failed / dropped</h2>
          <div class="overflow-x-auto rounded-box border border-error/40" id="gateway-dlq">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>When</th>
                  <th>Route</th>
                  <th>Status</th>
                  <th>Error</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={m <- @dead}>
                  <td>
                    <.local_time id={"gateway-dead-when-#{m.id}"} at={m.inserted_at} />
                  </td>
                  <td class="text-xs font-mono">{m.from_network} → {m.to_network}</td>
                  <td>
                    <% {label, class} = status_badge(m.status) %>
                    <span class={["badge badge-sm", class]}>{label}</span>
                  </td>
                  <td class="text-xs max-w-md truncate opacity-70" title={m.error}>
                    {m.error || "—"}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <div class="space-y-2">
          <div class="flex items-baseline justify-between gap-3">
            <h2 class="text-lg font-medium">Forward log</h2>
            <p class="text-xs opacity-50">Refreshes every 3s · no content stored or shown</p>
          </div>

          <div class="overflow-x-auto rounded-box border border-base-300">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>When</th>
                  <th>From</th>
                  <th>To</th>
                  <th>Status</th>
                  <th>Size</th>
                  <th>Error</th>
                </tr>
              </thead>
              <tbody>
                <tr :if={@entries == []}>
                  <td colspan="6" class="text-sm opacity-60">No forwards logged yet.</td>
                </tr>
                <tr :for={m <- @entries}>
                  <td>
                    <.local_time id={"gateway-when-#{m.id}"} at={m.inserted_at} />
                  </td>
                  <td class="text-xs">
                    <span class="font-medium">{m.from_network}</span>
                    <br />
                    <span
                      class="font-mono opacity-70"
                      title={format_identity_ref(m.from_network, m.from_ref)}
                    >
                      {short_identity_ref(m.from_network, m.from_ref)}
                    </span>
                  </td>
                  <td class="text-xs">
                    <span class="font-medium">{m.to_network}</span>
                    <br />
                    <span
                      class="font-mono opacity-70"
                      title={format_identity_ref(m.to_network, m.to_ref)}
                    >
                      {short_identity_ref(m.to_network, m.to_ref)}
                    </span>
                  </td>
                  <td>
                    <% {label, class} = status_badge(m.status) %>
                    <span class={["badge badge-sm", class]}>{label}</span>
                  </td>
                  <td class="text-xs font-mono whitespace-nowrap">{m.body_bytes} B</td>
                  <td class="text-xs max-w-xs truncate opacity-70" title={m.error}>
                    {m.error || "—"}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
