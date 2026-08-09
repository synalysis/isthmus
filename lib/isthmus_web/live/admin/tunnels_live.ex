defmodule IsthmusWeb.Admin.TunnelsLive do
  use IsthmusWeb, :live_view

  alias Isthmus.Announce.Governor
  alias Isthmus.Announce.Sightings
  alias Isthmus.Networks.LocalIdentity
  alias Isthmus.Tunnel
  alias Isthmus.Tunnel.Outbox
  alias Isthmus.Tunnel.Peer

  @default_carrier "meshcore"
  @default_payload "reticulum"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(3_000, self(), :refresh)

    {:ok,
     socket
     |> assign(:carrier, @default_carrier)
     |> assign(:payload, @default_payload)
     |> assign(:editing_peer, nil)
     |> assign(:edit_form, nil)
     |> assign(:edit_pairing, "")
     |> assign_local_identity()
     |> assign_data()}
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, assign_data(socket)}

  @impl true
  # phx-change fires on every keystroke. The payload/carrier selects must be
  # controlled from assigns, otherwise each re-render resets them to their first
  # <option> (dropping the operator's choice before submit). Resolving the local
  # identity can hit the RNS sidecar, so only do that when the carrier moves.
  def handle_event("form_changed", %{"peer" => peer}, socket) do
    socket = assign(socket, :payload, peer["payload_network"] || socket.assigns.payload)
    carrier = peer["carrier_network"] || socket.assigns.carrier

    socket =
      if carrier == socket.assigns.carrier do
        socket
      else
        socket
        |> assign(:carrier, carrier)
        |> assign_local_identity()
      end

    {:noreply, socket}
  end

  def handle_event("form_changed", _params, socket), do: {:noreply, socket}

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

  def handle_event("edit", %{"id" => id}, socket) do
    peer = Tunnel.get_peer!(id)

    {:noreply,
     socket
     |> assign(:editing_peer, peer)
     |> assign(:edit_form, to_form(Tunnel.change_peer(peer)))
     |> assign(:edit_pairing, "")}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, clear_edit(socket)}
  end

  def handle_event("validate_edit", %{"peer" => params}, socket) do
    case socket.assigns.editing_peer do
      nil ->
        {:noreply, socket}

      peer ->
        changeset = peer |> Tunnel.change_peer(params) |> Map.put(:action, :validate)

        {:noreply,
         socket
         |> assign(:edit_form, to_form(changeset))
         |> assign(:edit_pairing, params["pairing_code"] || "")}
    end
  end

  def handle_event("save_edit", %{"peer" => params}, socket) do
    case socket.assigns.editing_peer do
      nil ->
        {:noreply, socket}

      peer ->
        case Tunnel.update_peer(peer, params) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "Tunnel peer updated.")
             |> clear_edit()
             |> assign_data()}

          {:error, changeset} ->
            {:noreply, assign(socket, :edit_form, to_form(changeset))}
        end
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    peer = Tunnel.get_peer!(id)
    {:ok, _} = Tunnel.delete_peer(peer)

    socket =
      if socket.assigns.editing_peer && socket.assigns.editing_peer.id == peer.id do
        clear_edit(socket)
      else
        socket
      end

    {:noreply, socket |> put_flash(:info, "Tunnel peer deleted.") |> assign_data()}
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
    |> assign(:tunnel_health, Tunnel.Engine.health())
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

  defp clear_edit(socket) do
    socket
    |> assign(:editing_peer, nil)
    |> assign(:edit_form, nil)
    |> assign(:edit_pairing, "")
  end

  defp payload_networks, do: ~w(reticulum meshcore nostr)
  defp carrier_networks, do: ~w(meshcore reticulum nostr)
  defp network_options(networks), do: Enum.map(networks, &{&1, &1})

  defp editing?(nil, _peer), do: false
  defp editing?(%{id: id}, %{id: id}), do: true
  defp editing?(_editing, _peer), do: false

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
          phx-change="form_changed"
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
              <option value="reticulum" selected={@payload == "reticulum"}>Payload: reticulum</option>
              <option value="meshcore" selected={@payload == "meshcore"}>Payload: meshcore</option>
              <option value="nostr" selected={@payload == "nostr"}>Payload: nostr</option>
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

        <div class="space-y-1">
          <h2 class="text-lg font-medium">Tunnel peers</h2>
          <p class="text-xs opacity-60">
            Each enabled tunnel is pinged periodically over its carrier; the badge shows whether the
            far side is reachable and the round-trip time.
          </p>
        </div>

        <ul class="space-y-2">
          <li
            :for={peer <- @peers}
            id={"peer-#{peer.id}"}
            class="rounded-box border border-base-300 bg-base-200 px-4 py-3"
          >
            <%= if editing?(@editing_peer, peer) do %>
              <.form
                for={@edit_form}
                id={"edit-peer-#{peer.id}"}
                phx-change="validate_edit"
                phx-submit="save_edit"
                class="grid gap-3 md:grid-cols-2"
              >
                <h3 class="md:col-span-2 text-sm font-semibold">Edit tunnel peer</h3>
                <.input field={@edit_form[:name]} label="Name" />
                <.input field={@edit_form[:peer_ref]} label="Remote ref on carrier network" />
                <.input
                  field={@edit_form[:payload_network]}
                  type="select"
                  label="Payload"
                  options={network_options(payload_networks())}
                />
                <.input
                  field={@edit_form[:carrier_network]}
                  type="select"
                  label="Carrier"
                  options={network_options(carrier_networks())}
                />
                <div class="md:col-span-2">
                  <input
                    class="input input-bordered w-full"
                    name="peer[pairing_code]"
                    value={@edit_pairing}
                    placeholder="New shared tunnel code (optional — re-derives the tunnel id)"
                  />
                  <p class="mt-1 text-xs opacity-60">
                    Current tunnel id <span class="font-mono">{peer.tunnel_id}</span>.
                    Leave the code blank to keep it; enter an identical code on both sides to re-pair.
                  </p>
                </div>
                <div class="md:col-span-2 flex gap-2">
                  <button class="btn btn-primary btn-sm" type="submit">Save</button>
                  <button class="btn btn-ghost btn-sm" type="button" phx-click="cancel_edit">
                    Cancel
                  </button>
                </div>
              </.form>
            <% else %>
              <% health = Map.get(@tunnel_health, peer.tunnel_id) %>
              <% {health_label, health_class} = tunnel_badge(peer, health) %>
              <div class="flex flex-wrap items-center justify-between gap-2">
                <div class="space-y-1">
                  <p class="font-medium flex items-center gap-2">
                    {peer.name}
                    <span class={["badge badge-sm", health_class]}>{health_label}</span>
                    <span :if={Map.get(@preferred_ids, peer.id)} class="badge badge-success badge-sm">
                      preferred
                    </span>
                    <span :if={not peer.enabled} class="badge badge-ghost badge-sm">disabled</span>
                  </p>
                  <p class="text-xs font-mono opacity-70">
                    {peer.payload_network} over {peer.carrier_network} · {peer.tunnel_id} · seq {peer.next_seq}
                  </p>
                  <p :if={peer.enabled} class="text-xs opacity-70">
                    {tunnel_health_line(health)}
                  </p>
                  <p class="text-xs opacity-50">
                    {peer_metric_label(Map.get(@peer_metrics, peer.id))}
                  </p>
                </div>
                <div class="flex flex-wrap gap-2">
                  <button class="btn btn-sm" phx-click="toggle" phx-value-id={peer.id}>
                    {if peer.enabled, do: "Disable", else: "Enable"}
                  </button>
                  <button
                    class="btn btn-sm btn-outline"
                    id={"edit-#{peer.id}"}
                    phx-click="edit"
                    phx-value-id={peer.id}
                  >
                    Edit
                  </button>
                  <button
                    class="btn btn-sm btn-outline btn-error"
                    id={"delete-#{peer.id}"}
                    phx-click="delete"
                    phx-value-id={peer.id}
                    data-confirm={"Delete tunnel peer \"#{peer.name}\"? This cannot be undone."}
                  >
                    Delete
                  </button>
                </div>
              </div>
            <% end %>
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

  defp tunnel_badge(%{enabled: false}, _health), do: {"paused", "badge-ghost"}

  defp tunnel_badge(_peer, %{status: :reachable, rtt_ms: rtt}) when is_integer(rtt),
    do: {"reachable · #{rtt} ms", "badge-success"}

  defp tunnel_badge(_peer, %{status: :reachable}), do: {"reachable", "badge-success"}
  defp tunnel_badge(_peer, %{status: :unreachable}), do: {"unreachable", "badge-error"}
  defp tunnel_badge(_peer, _health), do: {"checking…", "badge-ghost"}

  defp tunnel_health_line(%{status: :reachable, rtt_ms: rtt, last_ack_at: ack})
       when is_integer(rtt) do
    "Round-trip #{rtt} ms · last reply #{ago(ack)} ago"
  end

  defp tunnel_health_line(%{status: :reachable, last_ack_at: ack}) do
    "Reachable · last reply #{ago(ack)} ago"
  end

  defp tunnel_health_line(%{status: :unreachable, last_ack_at: nil, misses: misses}) do
    "No reply yet · #{misses} ping(s) sent"
  end

  defp tunnel_health_line(%{status: :unreachable, last_ack_at: ack, misses: misses}) do
    "No reply · last ok #{ago(ack)} ago · #{misses} missed"
  end

  defp tunnel_health_line(_), do: "Awaiting first ping…"

  defp ago(nil), do: "—"

  defp ago(ms) when is_integer(ms) do
    secs = max(div(System.system_time(:millisecond) - ms, 1000), 0)

    cond do
      secs < 60 -> "#{secs}s"
      secs < 3600 -> "#{div(secs, 60)}m"
      true -> "#{div(secs, 3600)}h"
    end
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
