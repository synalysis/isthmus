defmodule IsthmusWeb.Admin.NostrLive do
  use IsthmusWeb, :live_view

  alias Isthmus.Networks.Nostr.RelayPool
  alias Isthmus.Networks.Nostr.ServiceInbox
  alias Isthmus.Nostr.Bech32
  alias Isthmus.Nostr.Crypto
  alias Isthmus.Relays
  alias Isthmus.Relays.Relay

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Isthmus.PubSub, ServiceInbox.topic())
      :timer.send_interval(3_000, self(), :refresh)
    end

    {:ok,
     socket
     |> assign(:page_title, "Nostr")
     |> assign_relays()}
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, assign_relays(socket)}

  def handle_info({:service_dm, _entry}, socket) do
    {:noreply, assign(socket, :service_dms, ServiceInbox.list(50))}
  end

  @impl true
  def handle_event("save", %{"relay" => params}, socket) do
    case Relays.create_relay(params) do
      {:ok, _relay} ->
        {:noreply,
         socket
         |> put_flash(:info, "Relay added.")
         |> assign_relays()
         |> assign(:form, to_form(Relays.change_relay(%Relay{})))}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    relay = Relays.get_relay!(id)
    {:ok, _} = Relays.delete_relay(relay)

    {:noreply,
     socket
     |> put_flash(:info, "Relay removed.")
     |> assign_relays()}
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    relay = Relays.get_relay!(id)
    {:ok, _} = Relays.update_relay(relay, %{enabled: !relay.enabled})
    {:noreply, assign_relays(socket)}
  end

  defp assign_relays(socket) do
    health = safe_pool_health()
    by_url = health[:by_url] || %{}

    rows =
      Relays.list_relays()
      |> Enum.map(fn relay ->
        info = Map.get(by_url, relay.url, %{status: :unknown})
        Map.put(relay, :runtime, info)
      end)

    service_npub =
      case Crypto.service_keypair() do
        {:ok, _, pk} -> Bech32.encode_npub(pk)
        _ -> nil
      end

    socket
    |> assign(:relays, rows)
    |> assign(:pool, health)
    |> assign(:service_npub, service_npub)
    |> assign(:service_dms, ServiceInbox.list(50))
    |> assign(:form, socket.assigns[:form] || to_form(Relays.change_relay(%Relay{})))
  end

  defp safe_pool_health do
    try do
      RelayPool.health()
    catch
      :exit, _ -> %{status: :down, online: 0, by_url: %{}}
    end
  end

  defp status_badge(:online), do: {"Connected", "badge-success"}
  defp status_badge(:connecting), do: {"Connecting", "badge-warning"}
  defp status_badge(:reconnecting), do: {"Reconnecting", "badge-warning"}
  defp status_badge(:down), do: {"Offline", "badge-error"}
  defp status_badge(:error), do: {"Error", "badge-error"}
  defp status_badge(:disabled), do: {"Offline", "badge-ghost"}
  defp status_badge(_), do: {"Unknown", "badge-ghost"}

  defp format_from(nil), do: "—"

  defp format_from(hex) when is_binary(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, bin} when byte_size(bin) == 32 -> Bech32.encode_npub(bin)
      _ -> hex
    end
  end

  defp format_age(%DateTime{} = at) do
    case DateTime.diff(DateTime.utc_now(), at) do
      s when s < 2 -> "just now"
      s when s < 60 -> "#{s}s ago"
      s when s < 3_600 -> "#{div(s, 60)}m ago"
      s -> "#{div(s, 3_600)}h ago"
    end
  end

  defp format_age(_), do: "—"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <section class="space-y-8 max-w-3xl">
        <div class="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
          <div>
            <h1 class="text-3xl font-semibold">Nostr</h1>
            <p class="text-sm opacity-70 mt-1">
              Relays and the Isthmus service identity. Group chat uses each group’s own
              proxy npub (see Groups) — not this key.
            </p>
          </div>
          <.admin_nav current={:nostr} />
        </div>

        <div class="card bg-base-200 border border-base-300" id="service-identity-card">
          <div class="card-body space-y-3">
            <h2 class="card-title text-base">Service identity</h2>
            <%= if @service_npub do %>
              <p class="font-mono text-sm break-all" id="service-npub">{@service_npub}</p>
              <p class="text-sm opacity-70">
                This Isthmus node’s Nostr address for tunnel carrier traffic (opaque frames
                demuxed by tunnel id). DMs sent here appear in the mailbox below only —
                they never fan out to groups. Group chat uses each group’s proxy npub.
              </p>
            <% else %>
              <p class="text-sm opacity-70">
                Set <code class="font-mono">ISTHMUS_NOSTR_NSEC</code>
                for this node’s tunnel carrier identity. Group DMs use per-group proxy keys.
              </p>
            <% end %>
          </div>
        </div>

        <div class="card bg-base-200 border border-base-300" id="service-inbox-card">
          <div class="card-body space-y-3">
            <div>
              <h2 class="card-title text-base">DMs to service identity</h2>
              <p class="text-xs opacity-70 mt-1">
                Operator mailbox only — no bridge fan-out.
              </p>
            </div>

            <%= if @service_dms == [] do %>
              <p class="text-sm opacity-70" id="service-inbox-empty">No messages yet.</p>
            <% else %>
              <ul class="space-y-3" id="service-inbox-list">
                <li
                  :for={dm <- @service_dms}
                  class="rounded-lg border border-base-300 bg-base-100/40 p-3 space-y-1"
                  id={"service-dm-#{dm.id}"}
                >
                  <div class="flex flex-wrap items-center justify-between gap-2 text-xs opacity-70">
                    <span class="font-mono truncate max-w-full">{format_from(dm.from_ref)}</span>
                    <span>{format_age(dm.received_at)}</span>
                  </div>
                  <p :if={dm.subject} class="text-xs opacity-60 font-mono">
                    subject: {dm.subject}
                  </p>
                  <p class="text-sm whitespace-pre-wrap break-words">{dm.body}</p>
                </li>
              </ul>
            <% end %>
          </div>
        </div>

        <div>
          <h2 class="text-xl font-medium mb-1">Relays</h2>
          <p class="text-sm opacity-70 mb-4">
            Pool {AdminCopy.status_plain(@pool[:status])} · {@pool[:online] || 0}/{@pool[
              :relays_enabled
            ] || 0} online · {@pool[:events_seen] || 0} events seen
          </p>

          <.form
            for={@form}
            id="relay-form"
            phx-submit="save"
            class="card bg-base-200 border border-base-300"
          >
            <div class="card-body grid gap-3 md:grid-cols-2">
              <div class="md:col-span-2">
                <label class="label"><span class="label-text">URL</span></label>
                <input
                  class="input input-bordered w-full"
                  type="text"
                  name="relay[url]"
                  placeholder="wss://relay.example.com"
                  value={@form[:url].value}
                />
              </div>
              <label class="label cursor-pointer justify-start gap-2">
                <input type="hidden" name="relay[read]" value="false" />
                <input type="checkbox" name="relay[read]" value="true" class="checkbox" checked />
                <span class="label-text">Read</span>
              </label>
              <label class="label cursor-pointer justify-start gap-2">
                <input type="hidden" name="relay[write]" value="false" />
                <input type="checkbox" name="relay[write]" value="true" class="checkbox" checked />
                <span class="label-text">Write</span>
              </label>
              <button class="btn btn-primary md:col-span-2" type="submit">Add relay</button>
            </div>
          </.form>
        </div>

        <ul class="space-y-2" id="nostr-relays-list">
          <li
            :for={relay <- @relays}
            class="flex flex-wrap items-center justify-between gap-2 rounded-box border border-base-300 bg-base-200 px-4 py-3"
          >
            <div class="min-w-0 flex-1">
              <div class="flex flex-wrap items-center gap-2">
                <p class="font-mono text-sm truncate">{relay.url}</p>
                <% {label, klass} = status_badge(relay.runtime[:status]) %>
                <span class={["badge badge-sm", klass]}>{label}</span>
              </div>
              <p class="text-xs opacity-60 mt-1">
                priority {relay.priority} · {if relay.read, do: "read", else: "no-read"} · {if relay.write,
                  do: "write",
                  else: "no-write"} · connects {relay.runtime[:connects] || 0} · drops {relay.runtime[
                  :disconnects
                ] || 0}
              </p>
              <p :if={relay.runtime[:last_error]} class="text-xs text-error mt-1 truncate max-w-xl">
                {relay.runtime[:last_error]}
              </p>
            </div>
            <div class="flex gap-2">
              <button class="btn btn-sm" phx-click="toggle" phx-value-id={relay.id}>
                {if relay.enabled, do: "Disable", else: "Enable"}
              </button>
              <button
                class="btn btn-sm btn-ghost text-error"
                phx-click="delete"
                phx-value-id={relay.id}
              >
                Delete
              </button>
            </div>
          </li>
        </ul>
      </section>
    </Layouts.app>
    """
  end
end
