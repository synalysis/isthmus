defmodule IsthmusWeb.Admin.MeshCoreLive do
  use IsthmusWeb, :live_view

  alias Isthmus.Networks.MeshCore.Companion
  alias Isthmus.QR
  alias Isthmus.Registrations

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Isthmus.PubSub, "meshcore:channels")
    end

    {:ok,
     socket
     |> assign(:page_title, "MeshCore")
     |> assign(:channel_syncing, false)
     |> assign(:channel_invite, nil)
     |> assign(:selected_bridge_id, nil)
     |> assign(:channel_bridge_form, to_form(%{"display_name" => ""}))
     |> assign(:channel_link_form, to_form(%{"group_id" => "", "channel_idx" => ""}))
     |> refresh()}
  end

  @impl true
  def handle_event("sync_meshcore_channels", _params, socket) do
    health = Companion.health()

    if health.status == :online do
      Companion.sync_channels_async()

      {:noreply,
       socket
       |> assign(:channel_syncing, true)
       |> assign(:companion_health, health)
       |> put_flash(:info, "Syncing MeshCore channels…")}
    else
      {:noreply,
       socket
       |> assign(:companion_health, health)
       |> put_flash(:error, "MeshCore companion offline — set ISTHMUS_MESHCORE_PORT.")}
    end
  end

  def handle_event("create_bridge_with_channel", %{"display_name" => name}, socket) do
    owner = socket.assigns.current_user.pubkey_hex

    result =
      try do
        Registrations.create_bridge_with_channel(owner, %{
          display_name: String.trim(name),
          created_by: "admin"
        })
      catch
        :exit, {:timeout, _} -> {:error, :timeout}
        :exit, reason -> {:error, {:exit, reason}}
      end

    case result do
      {:ok, group} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Bridge + MeshCore channel created (slot #{group.meshcore_channel_idx})."
         )
         |> assign(:selected_bridge_id, group.id)
         |> assign(:channel_bridge_form, to_form(%{"display_name" => ""}))
         |> assign(:channel_invite, nil)
         |> refresh()}

      {:error, :not_connected} ->
        {:noreply, put_flash(socket, :error, "MeshCore companion offline.")}

      {:error, :no_empty_channel_slot} ->
        {:noreply, put_flash(socket, :error, "No empty private channel slots (1–7).")}

      {:error, :timeout} ->
        {:noreply, put_flash(socket, :error, "Timed out talking to MeshCore companion.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not create: #{inspect(reason)}")}
    end
  end

  def handle_event("select_bridge", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:selected_bridge_id, id)
     |> assign(:channel_invite, nil)}
  end

  def handle_event("link_channel", params, socket) do
    group = Registrations.get_group!(params["group_id"])
    idx = String.to_integer(params["channel_idx"] || "0")

    with %{secret_hex: secret} when is_binary(secret) <- Companion.get_channel(idx),
         {:ok, _} <- Registrations.link_meshcore_channel(group, idx, secret) do
      {:noreply,
       socket
       |> assign(:selected_bridge_id, group.id)
       |> assign(:channel_invite, nil)
       |> put_flash(:info, "Channel #{idx} linked.")
       |> refresh()}
    else
      nil ->
        {:noreply, put_flash(socket, :error, "Channel not in companion cache — sync first.")}

      {:error, :channel_already_linked} ->
        {:noreply, put_flash(socket, :error, "Channel already linked to another group.")}

      {:error, :not_a_bridge_group} ->
        {:noreply, put_flash(socket, :error, "Only bridge groups can link channels.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Link failed: #{inspect(reason)}")}
    end
  end

  def handle_event("unlink_channel", %{"id" => id}, socket) do
    group = Registrations.get_group!(id)

    case Registrations.unlink_meshcore_channel(group) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:channel_invite, nil)
         |> put_flash(:info, "Channel unlinked.")
         |> refresh()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Unlink failed: #{inspect(reason)}")}
    end
  end

  def handle_event("show_channel_invite", %{"id" => id}, socket) do
    group = Registrations.get_group!(id)

    case Registrations.meshcore_channel_invite(group) do
      {:ok, invite} ->
        {:noreply,
         socket
         |> assign(:selected_bridge_id, group.id)
         |> assign(:channel_invite, invite)}

      {:error, :no_channel_linked} ->
        {:noreply, put_flash(socket, :error, "No MeshCore channel linked to this bridge.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not decrypt channel invite.")}
    end
  end

  def handle_event("hide_channel_invite", _params, socket) do
    {:noreply, assign(socket, :channel_invite, nil)}
  end

  @impl true
  def handle_info({:meshcore_channels, channels}, socket) when is_list(channels) do
    {:noreply,
     socket
     |> assign(:channel_syncing, false)
     |> assign(:meshcore_channels, Enum.sort_by(channels, & &1.index))
     |> assign(:companion_health, Companion.health())
     |> put_flash(:info, "Synced #{length(channels)} MeshCore channel slots.")}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp refresh(socket) do
    groups = Registrations.list_all()
    bridges = Enum.filter(groups, &(&1.kind == "bridge" and &1.status == "active"))

    selected_id = socket.assigns[:selected_bridge_id]

    selected =
      Enum.find(bridges, &(&1.id == selected_id)) ||
        Enum.find(bridges, &(&1.meshcore_channel_idx != nil)) ||
        List.first(bridges)

    socket
    |> assign(:groups, groups)
    |> assign(:bridges, bridges)
    |> assign(:selected_bridge, selected)
    |> assign(:selected_bridge_id, selected && selected.id)
    |> assign(:meshcore_channels, Companion.list_channels())
    |> assign(:companion_health, Companion.health())
    |> assign(:channel_syncing, socket.assigns[:channel_syncing] || false)
  end

  defp linked_group_name(groups, idx) do
    case Enum.find(groups, &(&1.status == "active" and &1.meshcore_channel_idx == idx)) do
      %{display_name: name} -> name
      _ -> nil
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <section class="space-y-8">
        <div class="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
          <div>
            <h1 class="text-3xl font-semibold">MeshCore</h1>
            <p class="mt-1 text-sm text-base-content/70">
              Companion radio, channel slots, and bridge channel invites.
            </p>
          </div>
          <.admin_nav current={:meshcore} />
        </div>

        <div class="flex flex-wrap items-center gap-3">
          <span class={[
            "badge",
            @companion_health.status == :online && "badge-success",
            @companion_health.status != :online && "badge-warning"
          ]}>
            companion {@companion_health.status}
          </span>
          <button
            class={["btn btn-outline btn-sm", @channel_syncing && "loading"]}
            phx-click="sync_meshcore_channels"
            id="sync-channels-btn"
            disabled={@channel_syncing}
          >
            {if(@channel_syncing, do: "Syncing…", else: "Sync channels")}
          </button>
          <.link navigate={~p"/admin/registrations"} class="link link-hover text-sm">
            Manage bridge members →
          </.link>
        </div>

        <%= if @companion_health.status != :online do %>
          <div class="alert alert-warning">
            Companion offline. Set <code>ISTHMUS_MESHCORE_PORT</code>
            (USB companion firmware) and sync.
          </div>
        <% else %>
          <div class="grid gap-6 lg:grid-cols-2">
            <div class="card bg-base-200 border border-base-300">
              <div class="card-body space-y-3">
                <h2 class="card-title text-lg">Create channel + bridge</h2>
                <p class="text-xs opacity-70">
                  Provisions slot 1–7 on the radio and links it to a new bridge group.
                </p>
                <.form
                  for={@channel_bridge_form}
                  id="channel-bridge-form"
                  phx-submit="create_bridge_with_channel"
                  class="space-y-3"
                >
                  <.input
                    field={@channel_bridge_form[:display_name]}
                    type="text"
                    label="Channel / group name"
                    placeholder="Trail crew"
                  />
                  <button class="btn btn-primary btn-sm" type="submit">Create on radio</button>
                </.form>
              </div>
            </div>

            <div class="card bg-base-200 border border-base-300">
              <div class="card-body space-y-3">
                <h2 class="card-title text-lg">Link existing channel</h2>
                <%= if @bridges == [] do %>
                  <p class="text-sm opacity-70">
                    Create a bridge on
                    <.link navigate={~p"/admin/registrations"} class="link">Groups</.link>
                    first, or use “Create channel + bridge”.
                  </p>
                <% else %>
                  <.form
                    for={@channel_link_form}
                    id="channel-link-form"
                    phx-submit="link_channel"
                    class="space-y-3"
                  >
                    <div>
                      <label class="label" for="link-bridge">
                        <span class="label-text">Bridge group</span>
                      </label>
                      <select id="link-bridge" name="group_id" class="select select-bordered w-full">
                        <option
                          :for={g <- @bridges}
                          value={g.id}
                          selected={g.id == @selected_bridge_id}
                        >
                          {g.display_name}
                        </option>
                      </select>
                    </div>
                    <div>
                      <label class="label" for="link-channel">
                        <span class="label-text">Channel slot</span>
                      </label>
                      <select
                        id="link-channel"
                        name="channel_idx"
                        class="select select-bordered w-full"
                      >
                        <option
                          :for={ch <- @meshcore_channels}
                          :if={not ch.empty?}
                          value={ch.index}
                        >
                          #{ch.index} — {ch.name || "unnamed"}
                        </option>
                      </select>
                    </div>
                    <button class="btn btn-primary btn-sm" type="submit">Link</button>
                  </.form>
                <% end %>
              </div>
            </div>
          </div>

          <div class="overflow-x-auto">
            <table class="table table-sm" id="meshcore-channels-table">
              <thead>
                <tr>
                  <th>Slot</th>
                  <th>Name</th>
                  <th>Status</th>
                  <th>Isthmus group</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={ch <- @meshcore_channels} id={"channel-#{ch.index}"}>
                  <td>{ch.index}</td>
                  <td>{if ch.empty?, do: "—", else: ch.name}</td>
                  <td>
                    <span class={[
                      "badge badge-sm",
                      ch.empty? && "badge-ghost",
                      not ch.empty? && "badge-primary"
                    ]}>
                      {if ch.empty?, do: "empty", else: "active"}
                    </span>
                  </td>
                  <td>{linked_group_name(@groups, ch.index) || "—"}</td>
                </tr>
              </tbody>
            </table>
          </div>
        <% end %>

        <div :if={@selected_bridge} class="space-y-3" id="channel-bridge-detail">
          <div class="flex flex-wrap items-center gap-2">
            <h2 class="text-xl font-medium">{@selected_bridge.display_name}</h2>
            <span class="badge badge-secondary badge-sm">bridge</span>
            <select
              id="invite-bridge-select"
              class="select select-bordered select-sm"
              phx-change="select_bridge"
              name="id"
            >
              <option :for={g <- @bridges} value={g.id} selected={g.id == @selected_bridge_id}>
                {g.display_name}
                <%= if g.meshcore_channel_idx != nil do %>
                  (slot {g.meshcore_channel_idx})
                <% end %>
              </option>
            </select>
          </div>

          <%= if @selected_bridge.meshcore_channel_idx != nil do %>
            <div
              class="space-y-3 rounded-lg border border-base-300 bg-base-200/50 p-4"
              id="channel-invite-section"
            >
              <div class="flex flex-wrap items-center gap-2">
                <p class="text-sm opacity-70 grow">
                  Linked MeshCore channel: slot {@selected_bridge.meshcore_channel_idx}
                </p>
                <%= if @channel_invite do %>
                  <button
                    type="button"
                    class="btn btn-ghost btn-xs"
                    id="hide-channel-invite-btn"
                    phx-click="hide_channel_invite"
                  >
                    Hide invite
                  </button>
                <% else %>
                  <button
                    type="button"
                    class="btn btn-outline btn-xs"
                    id="show-channel-invite-btn"
                    phx-click="show_channel_invite"
                    phx-value-id={@selected_bridge.id}
                  >
                    Show channel invite
                  </button>
                <% end %>
                <button
                  type="button"
                  class="btn btn-ghost btn-xs text-error"
                  phx-click="unlink_channel"
                  phx-value-id={@selected_bridge.id}
                >
                  Unlink
                </button>
              </div>

              <%= if @channel_invite do %>
                <p class="text-xs opacity-60">
                  On a second MeshCore device: join this channel, then send a message —
                  Isthmus fans it out to attached members (e.g. Reticulum).
                </p>

                <div class="grid gap-4 md:grid-cols-2" id="channel-invite-panel">
                  <div class="space-y-2" id="channel-invite-secret">
                    <h3 class="text-sm font-medium">Secret key</h3>
                    <p class="text-xs opacity-60">
                      MeshCore app → join with secret key. Name + 32-char hex.
                    </p>
                    <dl class="space-y-2 text-sm">
                      <div>
                        <dt class="text-xs opacity-60">Name</dt>
                        <dd class="font-mono select-all">{@channel_invite.name}</dd>
                      </div>
                      <div>
                        <dt class="text-xs opacity-60">Secret</dt>
                        <dd class="font-mono text-xs break-all select-all">
                          {@channel_invite.secret_hex}
                        </dd>
                      </div>
                      <div>
                        <dt class="text-xs opacity-60">Gateway slot (local)</dt>
                        <dd class="font-mono">{@channel_invite.slot}</dd>
                      </div>
                    </dl>
                  </div>

                  <div class="space-y-2" id="channel-invite-qr">
                    <h3 class="text-sm font-medium">QR code</h3>
                    <p class="text-xs opacity-60">
                      MeshCore app → join with QR code (or paste the URI).
                    </p>
                    <%= if qr = QR.svg(@channel_invite.uri) do %>
                      <div class="bg-white p-2 rounded-lg inline-block size-[236px]">
                        {Phoenix.HTML.raw(qr)}
                      </div>
                    <% end %>
                    <p class="font-mono text-xs break-all select-all opacity-80">
                      {@channel_invite.uri}
                    </p>
                  </div>
                </div>
              <% end %>
            </div>
          <% else %>
            <p class="text-sm opacity-70">
              This bridge has no MeshCore channel linked. Create or link one above.
            </p>
          <% end %>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
