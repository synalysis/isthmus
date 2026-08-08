defmodule IsthmusWeb.Admin.TunnelsLive do
  use IsthmusWeb, :live_view

  alias Isthmus.Announce.Governor
  alias Isthmus.Announce.Sightings
  alias Isthmus.Networks.LocalIdentity
  alias Isthmus.Tunnel
  alias Isthmus.Tunnel.Outbox
  alias Isthmus.Tunnel.Peer

  @default_carrier "meshcore"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(3_000, self(), :refresh)

    {:ok,
     socket
     |> assign(:carrier, @default_carrier)
     |> assign_local_identity()
     |> assign_data()}
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, assign_data(socket)}

  @impl true
  # phx-change fires on every keystroke in the form, but resolving the local
  # identity can hit the RNS sidecar, so only do it when the carrier moves.
  def handle_event("carrier_changed", %{"peer" => %{"carrier_network" => carrier}}, socket) do
    if carrier == socket.assigns.carrier do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(:carrier, carrier)
       |> assign_local_identity()}
    end
  end

  def handle_event("carrier_changed", _params, socket), do: {:noreply, socket}

  def handle_event("save", %{"peer" => params}, socket) do
    case Tunnel.create_peer(params) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Tunnel peer added.") |> assign_data()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    peer = Tunnel.get_peer!(id)
    {:ok, _} = Tunnel.update_peer(peer, %{enabled: !peer.enabled})
    {:noreply, assign_data(socket)}
  end

  def handle_event("retry_outbox", %{"id" => id}, socket) do
    case Outbox.retry(id) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Re-queued for delivery.") |> assign_data()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Retry failed: #{inspect(reason)}")}
    end
  end

  def handle_event("drop_outbox", %{"id" => id}, socket) do
    case Outbox.drop(id) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, "Dropped from DLQ.") |> assign_data()}
      {:error, reason} -> {:noreply, put_flash(socket, :error, "Drop failed: #{inspect(reason)}")}
    end
  end

  defp assign_data(socket) do
    peers = Tunnel.list_peers()
    peer_refs = peers |> Enum.map(& &1.peer_ref) |> Enum.uniq()

    routing_notes =
      peer_refs
      |> Enum.filter(fn ref -> length(Tunnel.candidates(ref)) > 1 end)
      |> Map.new(fn ref -> {ref, Tunnel.routing_choice(ref)} end)

    peer_metrics =
      Map.new(peers, fn peer ->
        sighting = Sightings.latest_for_tunnel(peer.tunnel_id)
        {peer.id, %{sighting: sighting, score: Tunnel.score_peer(peer)}}
      end)

    preferred_ids =
      routing_notes
      |> Enum.map(fn {_ref, %{best: best}} -> best end)
      |> Enum.reject(&is_nil/1)
      |> Map.new(&{&1.id, true})

    socket
    |> assign(:page_title, "Tunnels")
    |> assign(:peers, peers)
    |> assign(:peer_metrics, peer_metrics)
    |> assign(:preferred_ids, preferred_ids)
    |> assign(:routing_notes, routing_notes)
    |> assign(:sightings, Sightings.list_recent(50))
    |> assign(:outbox, Outbox.stats())
    |> assign(:dlq, Outbox.list_failed(30))
    |> assign(:governor, Governor.stats())
    |> assign(:drops, Governor.drops_by_reason(20))
    |> assign(:form, socket.assigns[:form] || to_form(Tunnel.change_peer(%Peer{})))
  end

  defp assign_local_identity(socket) do
    assign(socket, :local_identity, LocalIdentity.for_network(socket.assigns.carrier))
  end

  defp identity_badge(:ok), do: {"ready", "badge-success"}
  defp identity_badge(:partial), do: {"see note", "badge-warning"}
  defp identity_badge(:pending), do: {"waiting", "badge-ghost"}
  defp identity_badge(_), do: {"unavailable", "badge-ghost"}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <section class="space-y-8">
        <div class="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
          <div>
            <h1 class="text-3xl font-semibold">Tunnels & governor</h1>
          </div>
          <.admin_nav current={:tunnels} />
        </div>

        <div class="grid gap-4 md:grid-cols-4">
          <div class="stat bg-base-200 rounded-box border border-base-300">
            <div class="stat-title">Outbox pending</div>
            <div class="stat-value text-2xl">{@outbox["pending"] || 0}</div>
          </div>
          <div class="stat bg-base-200 rounded-box border border-base-300">
            <div class="stat-title">Outbox failed</div>
            <div class="stat-value text-2xl">{@outbox["failed"] || 0}</div>
          </div>
          <div class="stat bg-base-200 rounded-box border border-base-300">
            <div class="stat-title">Governor allowed</div>
            <div class="stat-value text-2xl">{@governor.allowed}</div>
          </div>
          <div class="stat bg-base-200 rounded-box border border-base-300">
            <div class="stat-title">Sightings (24h)</div>
            <div class="stat-value text-2xl">{length(@sightings)}</div>
          </div>
        </div>

        <div :if={@dlq != []} class="space-y-2">
          <h2 class="text-lg font-medium">Dead letter queue</h2>
          <p class="text-xs opacity-60">
            Failed outbox frames after max retries. Retry or drop permanently.
          </p>
          <div class="overflow-x-auto rounded-box border border-base-300">
            <table class="table table-sm" id="outbox-dlq">
              <thead>
                <tr>
                  <th>Channel</th>
                  <th>Destination</th>
                  <th>Attempts</th>
                  <th>Error</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <tr :for={m <- @dlq} id={"dlq-#{m.id}"}>
                  <td class="font-mono text-xs">{m.channel}</td>
                  <td class="font-mono text-xs" title={m.destination}>{short_ref(m.destination)}</td>
                  <td class="text-xs">{m.attempts}</td>
                  <td class="text-xs max-w-xs truncate opacity-70" title={m.last_error}>
                    {m.last_error || "—"}
                  </td>
                  <td class="whitespace-nowrap">
                    <button
                      type="button"
                      id={"retry-#{m.id}"}
                      class="btn btn-ghost btn-xs"
                      phx-click="retry_outbox"
                      phx-value-id={m.id}
                    >
                      Retry
                    </button>
                    <button
                      type="button"
                      id={"drop-#{m.id}"}
                      class="btn btn-ghost btn-xs text-error"
                      phx-click="drop_outbox"
                      phx-value-id={m.id}
                      data-confirm="Drop this message permanently?"
                    >
                      Drop
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <div :if={map_size(@routing_notes) > 0} class="space-y-2">
          <h2 class="text-lg font-medium">Route selection</h2>
          <div
            :for={{ref, choice} <- @routing_notes}
            class="rounded-box border border-base-300 bg-base-200 px-4 py-3 text-sm"
          >
            <p class="font-mono text-xs opacity-70 break-all">{ref}</p>
            <p class="mt-1">
              Preferred: <span class="font-medium">{choice.best && choice.best.name}</span>
              <span :if={choice.best} class="font-mono text-xs opacity-70">
                · {choice.best.tunnel_id}
              </span>
            </p>
            <p class="text-xs opacity-60 mt-1">
              {routing_reason(choice)}
            </p>
          </div>
        </div>

        <.form
          for={@form}
          id="peer-form"
          phx-change="carrier_changed"
          phx-submit="save"
          class="card bg-base-200 border border-base-300"
        >
          <div class="card-body grid gap-3 md:grid-cols-2">
            <h2 class="card-title md:col-span-2">Add tunnel peer</h2>
            <input class="input input-bordered" name="peer[name]" placeholder="Name" required />
            <input
              class="input input-bordered"
              name="peer[peer_ref]"
              placeholder="Remote's ref on the carrier network"
              required
            />
            <div class="md:col-span-2">
              <input
                class="input input-bordered w-full"
                name="peer[pairing_code]"
                placeholder="Shared tunnel code — both sides enter the same phrase"
              />
              <p class="mt-1 text-xs opacity-60">
                Both endpoints must derive the same tunnel id: enter an identical code on each side
                (case-insensitive). Inbound frames are demuxed by tunnel id, not by carrier address,
                so a return path only works when both sides match. Leave blank for a one-off random
                tunnel (outbound only until the other side pairs the id).
              </p>
            </div>
            <select class="select select-bordered" name="peer[payload_network]">
              <option value="reticulum">Payload: reticulum</option>
              <option value="meshcore">Payload: meshcore</option>
              <option value="nostr">Payload: nostr</option>
            </select>
            <select class="select select-bordered" name="peer[carrier_network]" value={@carrier}>
              <option value="meshcore" selected={@carrier == "meshcore"}>Carrier: meshcore</option>
              <option value="reticulum" selected={@carrier == "reticulum"}>
                Carrier: reticulum
              </option>
              <option value="nostr" selected={@carrier == "nostr"}>Carrier: nostr</option>
            </select>

            <div
              id="local-identity"
              class="md:col-span-2 rounded-box border border-base-300 bg-base-100 p-3 space-y-2"
            >
              <div class="flex flex-wrap items-center justify-between gap-2">
                <h3 class="text-sm font-semibold">
                  Your ref on {@local_identity.network}
                </h3>
                <% {badge_label, badge_class} = identity_badge(@local_identity.status) %>
                <span class={["badge badge-sm", badge_class]}>{badge_label}</span>
              </div>

              <p class="text-xs opacity-70">
                Send this to the remote operator — they enter it as the peer ref on their side.
              </p>

              <div :for={{ref, idx} <- Enum.with_index(@local_identity.refs)} class="flex gap-2">
                <code class="flex-1 select-all break-all rounded-lg bg-base-200 px-2 py-1.5 font-mono text-xs">
                  {ref}
                </code>
                <button
                  type="button"
                  id={"copy-local-ref-#{idx}"}
                  phx-hook=".CopyRef"
                  data-ref={ref}
                  class="btn btn-sm btn-outline shrink-0"
                >
                  Copy
                </button>
              </div>

              <p :if={@local_identity.note} class="text-xs opacity-70">{@local_identity.note}</p>
              <p :if={@local_identity.hint} class="text-xs opacity-60">{@local_identity.hint}</p>
            </div>

            <button class="btn btn-primary md:col-span-2" type="submit">Create</button>
          </div>
          <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyRef">
            export default {
              mounted() {
                this.el.addEventListener("click", async () => {
                  const ref = this.el.dataset.ref
                  if (!ref) { return }
                  try {
                    await navigator.clipboard.writeText(ref)
                  } catch (_err) {
                    return
                  }
                  const original = this.el.textContent
                  this.el.textContent = "Copied"
                  setTimeout(() => { this.el.textContent = original }, 1200)
                })
              }
            }
          </script>
        </.form>

        <ul class="space-y-2">
          <li
            :for={peer <- @peers}
            class="flex flex-wrap items-center justify-between gap-2 rounded-box border border-base-300 bg-base-200 px-4 py-3"
          >
            <div class="space-y-1">
              <p class="font-medium flex items-center gap-2">
                {peer.name}
                <span :if={Map.get(@preferred_ids, peer.id)} class="badge badge-success badge-sm">
                  preferred
                </span>
              </p>
              <p class="text-xs font-mono opacity-70">
                {peer.payload_network} over {peer.carrier_network} · {peer.tunnel_id} · seq {peer.next_seq}
              </p>
              <p class="text-xs opacity-60">
                {peer_metric_label(Map.get(@peer_metrics, peer.id))}
              </p>
            </div>
            <button class="btn btn-sm" phx-click="toggle" phx-value-id={peer.id}>
              {if peer.enabled, do: "Disable", else: "Enable"}
            </button>
          </li>
        </ul>

        <div>
          <h2 class="text-xl font-medium mb-2">Announce flow (24h)</h2>
          <div class="overflow-x-auto rounded-box border border-base-300">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>When</th>
                  <th>Net</th>
                  <th>Dir</th>
                  <th>Identity</th>
                  <th>Hops</th>
                  <th>Latency</th>
                  <th>Tunnel</th>
                </tr>
              </thead>
              <tbody>
                <tr :if={@sightings == []}>
                  <td colspan="7" class="text-sm opacity-60">No sightings yet.</td>
                </tr>
                <tr :for={s <- @sightings}>
                  <td class="text-xs whitespace-nowrap">{s.seen_at}</td>
                  <td class="text-xs">{s.network}</td>
                  <td class="text-xs">{s.direction}</td>
                  <td class="text-xs font-mono max-w-xs truncate" title={s.identity_ref}>
                    {short_ref(s.identity_ref)}
                  </td>
                  <td class="text-xs font-mono">{s.hops || "—"}</td>
                  <td class="text-xs font-mono">
                    {if s.latency_ms, do: "#{s.latency_ms} ms", else: "—"}
                  </td>
                  <td class="text-xs font-mono truncate max-w-[8rem]" title={s.tunnel_id}>
                    {s.tunnel_id || "—"}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <div>
          <h2 class="text-xl font-medium mb-2">Recent governor drops</h2>
          <ul class="text-sm space-y-1">
            <li :for={drop <- @drops} class="font-mono opacity-80">
              {drop.network}/{drop.class} {drop.reason} · {drop.identity_key}
            </li>
          </ul>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp peer_metric_label(nil), do: "No path metrics yet"

  defp peer_metric_label(%{sighting: nil, score: score}) do
    "No sightings · score #{score}"
  end

  defp peer_metric_label(%{sighting: s, score: score}) do
    hops = if s.hops != nil, do: "hops=#{s.hops}", else: "hops=?"
    lat = if s.latency_ms, do: "#{s.latency_ms}ms", else: "—"
    "Last #{s.seen_at} · #{hops} · #{lat} · score #{score}"
  end

  defp routing_reason(%{best: best, scores: scores}) when not is_nil(best) do
    mine = Map.get(scores, best.tunnel_id, %{})
    sighting = mine[:sighting]

    hops =
      case sighting do
        %{hops: h} when is_integer(h) -> "hops=#{h}"
        _ -> "hops=?"
      end

    lat =
      case sighting do
        %{latency_ms: ms} when is_integer(ms) -> "#{ms}ms RTT"
        _ -> "no RTT yet"
      end

    "Chosen for #{hops}, #{lat} (lowest score among alternatives)"
  end

  defp routing_reason(_), do: ""

  defp short_ref(ref) when is_binary(ref) do
    if String.length(ref) > 16 do
      String.slice(ref, 0, 8) <> "…" <> String.slice(ref, -6, 6)
    else
      ref
    end
  end

  defp short_ref(_), do: "—"
end
