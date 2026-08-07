defmodule IsthmusWeb.Admin.RegistrationsLive do
  use IsthmusWeb, :live_view

  alias Isthmus.Registrations

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Groups")
     |> assign(:bridge_form, to_form(%{"display_name" => ""}))
     |> assign(:attach_form, to_form(%{"group_id" => "", "network" => "nostr", "identity" => ""}))
     |> assign(:selected_bridge_id, nil)
     |> refresh()}
  end

  @impl true
  def handle_event("revoke", %{"id" => id}, socket) do
    group = Registrations.get_group!(id)
    {:ok, _} = Registrations.revoke(group)

    {:noreply,
     socket
     |> put_flash(:info, "Revoked.")
     |> refresh()}
  end

  def handle_event("announce", %{"id" => id}, socket) do
    group = Registrations.get_group!(id)

    case Registrations.announce_group(group) do
      {:ok, results} ->
        msg =
          results
          |> Enum.map(fn
            {net, :ok} -> "#{net}: ok"
            {net, {:error, reason}} -> "#{net}: #{inspect(reason)}"
          end)
          |> Enum.join("; ")

        {:noreply,
         socket
         |> put_flash(:info, "Announce — #{msg}")
         |> refresh()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Announce failed: #{inspect(reason)}")}
    end
  end

  def handle_event("announce_leg", %{"group_id" => gid, "leg_id" => leg_id}, socket) do
    group = Registrations.get_group!(gid)
    leg = Enum.find(group.legs, &(&1.id == leg_id))

    case leg && Registrations.announce_leg(leg) do
      :ok ->
        {:noreply, put_flash(socket, :info, "Announced on #{leg.network}.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Announce failed: #{inspect(reason)}")}

      nil ->
        {:noreply, put_flash(socket, :error, "Leg not found.")}
    end
  end

  def handle_event("ensure_bridge_proxy", %{"id" => id}, socket) do
    group = Registrations.get_group!(id)

    case Registrations.ensure_bridge_rns_proxy(group) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Bridge RNS proxy minted.")
         |> refresh()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Mint failed: #{inspect(reason)}")}
    end
  end

  def handle_event("ensure_nostr_proxy", %{"id" => id}, socket) do
    group = Registrations.get_group!(id)

    case Registrations.ensure_nostr_proxy(group) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Nostr proxy minted.")
         |> refresh()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Mint failed: #{inspect(reason)}")}
    end
  end

  def handle_event("create_bridge", %{"display_name" => name}, socket) do
    owner = socket.assigns.current_user.pubkey_hex

    case Registrations.create_bridge_group(owner, %{
           display_name: String.trim(name),
           created_by: "admin"
         }) do
      {:ok, group} ->
        {:noreply,
         socket
         |> put_flash(:info, "Bridge group created.")
         |> assign(:selected_bridge_id, group.id)
         |> assign(:bridge_form, to_form(%{"display_name" => ""}))
         |> refresh()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not create: #{inspect(reason)}")}
    end
  end

  def handle_event("select_bridge", %{"id" => id}, socket) do
    {:noreply,
     socket
     |> assign(:selected_bridge_id, id)
     |> assign(
       :attach_form,
       to_form(%{"group_id" => id, "network" => "nostr", "identity" => ""})
     )
     |> refresh()}
  end

  def handle_event("attach_member", params, socket) do
    group = Registrations.get_group!(params["group_id"])

    case Registrations.attach_member(
           group,
           params["network"],
           String.trim(params["identity"] || "")
         ) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Member attached.")
         |> assign(
           :attach_form,
           to_form(%{
             "group_id" => group.id,
             "network" => params["network"],
             "identity" => ""
           })
         )
         |> refresh()}

      {:error, :identity_already_linked} ->
        {:noreply, put_flash(socket, :error, "Identity already linked to another group.")}

      {:error, :not_a_bridge_group} ->
        {:noreply, put_flash(socket, :error, "Not a bridge group.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, put_flash(socket, :error, attach_changeset_error(changeset))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Attach failed: #{inspect(reason)}")}
    end
  end

  def handle_event("detach_member", %{"leg_id" => leg_id, "group_id" => group_id}, socket) do
    group = Registrations.get_group!(group_id)
    leg = Enum.find(group.legs, &(&1.id == leg_id))

    case leg && Registrations.detach_member(leg) do
      :ok ->
        {:noreply, socket |> put_flash(:info, "Member detached.") |> refresh()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Detach failed: #{inspect(reason)}")}

      nil ->
        {:noreply, put_flash(socket, :error, "Leg not found.")}
    end
  end

  defp refresh(socket) do
    groups = Registrations.list_all()
    bridges = Enum.filter(groups, &(&1.kind == "bridge" and &1.status == "active"))

    selected =
      Enum.find(bridges, &(&1.id == socket.assigns.selected_bridge_id)) || List.first(bridges)

    socket
    |> assign(:groups, groups)
    |> assign(:bridges, bridges)
    |> assign(:selected_bridge, selected)
    |> assign(:selected_bridge_id, selected && selected.id)
  end

  defp attach_changeset_error(%Ecto.Changeset{} = changeset) do
    if Keyword.has_key?(changeset.errors, :network) or
         Keyword.has_key?(changeset.errors, :identity_ref) do
      "Identity already linked to another group."
    else
      "Attach failed: #{inspect(changeset.errors)}"
    end
  end

  defp announceable_legs(%{status: "active", legs: legs}) when is_list(legs) do
    Enum.filter(legs, &Registrations.can_announce_leg?/1)
  end

  defp announceable_legs(_), do: []

  defp needs_bridge_proxy?(%{kind: "bridge", status: "active", legs: legs}) when is_list(legs) do
    not Enum.any?(legs, &(&1.network == "reticulum" and &1.role == "proxy"))
  end

  defp needs_bridge_proxy?(_), do: false

  defp needs_nostr_proxy?(%{status: "active", legs: legs}) when is_list(legs) do
    not Enum.any?(legs, &(&1.network == "nostr" and &1.role == "proxy"))
  end

  defp needs_nostr_proxy?(_), do: false

  defp token_for(group), do: Registrations.token_slug(group.display_name)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <section class="space-y-10">
        <div class="flex flex-col gap-4 lg:flex-row lg:items-start lg:justify-between">
          <div>
            <h1 class="text-3xl font-semibold">Groups</h1>
            <p class="mt-1 text-sm text-base-content/70">
              Registrations mint proxies. Bridge groups only attach real identities.
              MeshCore channels are configured under <.link
                navigate={~p"/admin/meshcore"}
                class="link"
              >MeshCore</.link>.
            </p>
          </div>
          <.admin_nav current={:groups} />
        </div>

        <div class="grid gap-6 lg:grid-cols-2">
          <div class="card bg-base-200 border border-base-300">
            <div class="card-body space-y-3">
              <h2 class="card-title text-lg">New bridge group</h2>
              <.form
                for={@bridge_form}
                id="bridge-create-form"
                phx-submit="create_bridge"
                class="space-y-3"
              >
                <.input
                  field={@bridge_form[:display_name]}
                  type="text"
                  label="Display name"
                  placeholder="Camp bridge"
                />
                <button class="btn btn-primary btn-sm" type="submit">Create</button>
              </.form>
            </div>
          </div>

          <div class="card bg-base-200 border border-base-300">
            <div class="card-body space-y-3">
              <h2 class="card-title text-lg">Attach member</h2>
              <%= if @bridges == [] do %>
                <p class="text-sm opacity-70">Create a bridge group first.</p>
              <% else %>
                <.form
                  for={@attach_form}
                  id="bridge-attach-form"
                  phx-submit="attach_member"
                  class="space-y-3"
                >
                  <input type="hidden" name="group_id" value={@selected_bridge_id} />
                  <div>
                    <label class="label" for="attach-group">
                      <span class="label-text">Bridge group</span>
                    </label>
                    <select
                      id="attach-group"
                      class="select select-bordered w-full"
                      phx-change="select_bridge"
                      name="id"
                    >
                      <option
                        :for={g <- @bridges}
                        value={g.id}
                        selected={g.id == @selected_bridge_id}
                      >
                        {g.display_name} ({length(g.legs)} members)
                      </option>
                    </select>
                  </div>
                  <.input
                    field={@attach_form[:network]}
                    type="select"
                    label="Network"
                    options={[
                      {"Nostr", "nostr"},
                      {"MeshCore", "meshcore"},
                      {"Reticulum", "reticulum"}
                    ]}
                  />
                  <.input
                    field={@attach_form[:identity]}
                    type="text"
                    label="Identity"
                    placeholder="npub / MeshCore pubkey / RNS dest hash"
                  />
                  <button class="btn btn-primary btn-sm" type="submit">Attach</button>
                </.form>
              <% end %>
            </div>
          </div>
        </div>

        <div :if={@selected_bridge} class="space-y-3">
          <h2 class="text-xl font-medium">
            {@selected_bridge.display_name}
            <span class="badge badge-secondary badge-sm ml-2">bridge</span>
          </h2>
          <p class="text-sm opacity-70">
            MeshCore address token: <code class="font-mono">@{token_for(@selected_bridge)}</code>
          </p>
          <%= if @selected_bridge.meshcore_channel_idx != nil do %>
            <p class="text-sm opacity-70" id="bridge-channel-badge">
              Linked MeshCore channel: slot {@selected_bridge.meshcore_channel_idx} ·
              <.link navigate={~p"/admin/meshcore"} class="link">
                Manage invite / unlink on MeshCore →
              </.link>
            </p>
          <% else %>
            <p class="text-sm opacity-70">
              No MeshCore channel linked.
              <.link navigate={~p"/admin/meshcore"} class="link">Configure on MeshCore →</.link>
            </p>
          <% end %>
          <div class="overflow-x-auto">
            <table class="table table-sm" id="bridge-members-table">
              <thead>
                <tr>
                  <th>Network</th>
                  <th>Identity</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <tr :for={leg <- @selected_bridge.legs} id={"member-#{leg.id}"}>
                  <td class="capitalize">{leg.network}</td>
                  <td class="font-mono text-xs break-all">{leg.identity_ref}</td>
                  <td>
                    <button
                      class="btn btn-ghost btn-xs text-error"
                      phx-click="detach_member"
                      phx-value-leg_id={leg.id}
                      phx-value-group_id={@selected_bridge.id}
                    >
                      Detach
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <div>
          <h2 class="text-xl font-medium mb-3">All groups</h2>
          <div class="overflow-x-auto">
            <table class="table" id="groups-table">
              <thead>
                <tr>
                  <th>Kind</th>
                  <th>Owner</th>
                  <th>Name</th>
                  <th>Status</th>
                  <th>Legs</th>
                  <th>MC ch</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <tr :for={group <- @groups} id={"group-#{group.id}"}>
                  <td>
                    <span class={[
                      "badge badge-sm",
                      group.kind == "bridge" && "badge-secondary",
                      group.kind != "bridge" && "badge-ghost"
                    ]}>
                      {group.kind}
                    </span>
                  </td>
                  <td class="font-mono text-xs break-all max-w-xs">{group.owner_pubkey_hex}</td>
                  <td>{group.display_name}</td>
                  <td><span class="badge">{group.status}</span></td>
                  <td>
                    <div class="flex flex-wrap gap-1">
                      <span :for={leg <- group.legs} class="badge badge-ghost badge-sm capitalize">
                        {leg.network}/{leg.role}
                      </span>
                    </div>
                  </td>
                  <td>
                    <%= if group.meshcore_channel_idx != nil do %>
                      <span class="badge badge-primary badge-sm">{group.meshcore_channel_idx}</span>
                    <% else %>
                      —
                    <% end %>
                  </td>
                  <td>
                    <div class="flex flex-wrap gap-1 justify-end">
                      <button
                        :if={group.kind == "bridge" and group.status == "active"}
                        class="btn btn-ghost btn-xs"
                        phx-click="select_bridge"
                        phx-value-id={group.id}
                      >
                        Manage
                      </button>
                      <button
                        :if={needs_bridge_proxy?(group)}
                        class="btn btn-secondary btn-xs"
                        phx-click="ensure_bridge_proxy"
                        phx-value-id={group.id}
                      >
                        Mint RNS proxy
                      </button>
                      <button
                        :if={needs_nostr_proxy?(group)}
                        class="btn btn-secondary btn-xs"
                        phx-click="ensure_nostr_proxy"
                        phx-value-id={group.id}
                      >
                        Mint Nostr proxy
                      </button>
                      <button
                        :if={group.status == "active" and announceable_legs(group) != []}
                        class="btn btn-outline btn-xs"
                        phx-click="announce"
                        phx-value-id={group.id}
                      >
                        Announce
                      </button>
                      <button
                        :for={leg <- announceable_legs(group)}
                        class="btn btn-ghost btn-xs"
                        phx-click="announce_leg"
                        phx-value-group_id={group.id}
                        phx-value-leg_id={leg.id}
                      >
                        {leg.network}
                      </button>
                      <button
                        :if={group.status != "revoked"}
                        class="btn btn-ghost btn-xs text-error"
                        phx-click="revoke"
                        phx-value-id={group.id}
                      >
                        Revoke
                      </button>
                    </div>
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
