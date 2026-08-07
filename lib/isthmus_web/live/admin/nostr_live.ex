defmodule IsthmusWeb.Admin.NostrLive do
  use IsthmusWeb, :live_view

  alias Isthmus.Networks.Nostr.RelayPool
  alias Isthmus.Nostr.Bech32
  alias Isthmus.Nostr.Crypto
  alias Isthmus.Relays
  alias Isthmus.Relays.Relay

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(3_000, self(), :refresh)

    {:ok,
     socket
     |> assign(:page_title, "Nostr")
     |> assign_relays()}
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, assign_relays(socket)}

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
    |> assign(:form, socket.assigns[:form] || to_form(Relays.change_relay(%Relay{})))
  end

  defp safe_pool_health do
    try do
      RelayPool.health()
    catch
      :exit, _ -> %{status: :down, online: 0, by_url: %{}}
    end
  end

  defp status_badge(:online), do: {"online", "badge-success"}
  defp status_badge(:connecting), do: {"connecting", "badge-warning"}
  defp status_badge(:reconnecting), do: {"reconnecting", "badge-warning"}
  defp status_badge(:down), do: {"down", "badge-error"}
  defp status_badge(:error), do: {"error", "badge-error"}
  defp status_badge(:disabled), do: {"disabled", "badge-ghost"}
  defp status_badge(_), do: {"unknown", "badge-ghost"}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <section class="space-y-8 max-w-3xl">
        <div class="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
          <div>
            <h1 class="text-3xl font-semibold">Nostr</h1>
            <p class="text-sm opacity-70 mt-1">
              Relays and service identity for DM bridging.
            </p>
          </div>
          <.admin_nav current={:nostr} />
        </div>

        <div class="alert alert-info text-sm">
          <%= if @service_npub do %>
            Service identity: <span class="font-mono">{@service_npub}</span>
            — users DM this key to reach their MeshCore/RNS proxies.
          <% else %>
            Set <code>ISTHMUS_NOSTR_NSEC</code> to enable Nostr DM bridging via a service identity.
          <% end %>
        </div>

        <div>
          <h2 class="text-xl font-medium mb-1">Relays</h2>
          <p class="text-sm opacity-70 mb-4">
            Pool {@pool[:status]} · {@pool[:online] || 0}/{@pool[:relays_enabled] || 0} online · {@pool[
              :events_seen
            ] || 0} events seen
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
