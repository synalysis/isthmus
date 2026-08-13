defmodule IsthmusWeb.Admin.RegistrationsLive do
  use IsthmusWeb, :live_view

  alias Isthmus.Announce.KnownAddresses
  alias Isthmus.Registrations

  @impl true
  @default_attach_network "meshcore"

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Groups")
     |> assign(:modal, nil)
     |> assign(:show_revoked, false)
     |> assign(:bridge_form, to_form(%{"display_name" => ""}))
     |> assign(:attach_form, to_form(%{"group_id" => "", "network" => "nostr", "identity" => ""}))
     |> assign(:attach_network, "nostr")
     |> assign(:attach_group_id, nil)
     |> assign(:attach_group_name, nil)
     |> assign(:identity_suggestions, [])
     |> assign(:filtered_suggestions, [])
     |> assign(:selected_bridge_id, nil)
     |> refresh()}
  end

  @impl true
  def handle_event("toggle_show_revoked", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_revoked, !socket.assigns.show_revoked)
     |> refresh()}
  end

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
         |> assign(:modal, nil)
         |> refresh()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not create: #{inspect(reason)}")}
    end
  end

  def handle_event("select_bridge", %{"id" => id}, socket) do
    {:noreply, socket |> assign(:selected_bridge_id, id) |> refresh()}
  end

  def handle_event("open_new_group", _params, socket) do
    {:noreply,
     socket
     |> assign(:bridge_form, to_form(%{"display_name" => ""}))
     |> assign(:modal, :new_group)}
  end

  def handle_event("open_attach", %{"id" => id}, socket) do
    group = Enum.find(socket.assigns.groups, &(&1.id == id))
    network = @default_attach_network
    suggestions = KnownAddresses.for_network(network)

    {:noreply,
     socket
     |> assign(:attach_group_id, id)
     |> assign(:attach_group_name, group && group.display_name)
     |> assign(:attach_network, network)
     |> assign(:identity_suggestions, suggestions)
     |> assign(:filtered_suggestions, filter_suggestions(suggestions, "", network))
     |> assign(
       :attach_form,
       to_form(%{"group_id" => id, "network" => network, "identity" => ""})
     )
     |> assign(:modal, :attach)}
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply, assign(socket, :modal, nil)}
  end

  # Refresh address suggestions when the target network changes; suggestions are
  # recomputed only on an actual network switch, and filtered as the admin types.
  def handle_event("attach_form_changed", params, socket) do
    network = params["network"] || socket.assigns.attach_network
    identity = params["identity"] || ""
    network_changed? = network != socket.assigns.attach_network

    suggestions =
      if network_changed?,
        do: KnownAddresses.for_network(network),
        else: socket.assigns.identity_suggestions

    {:noreply,
     socket
     |> assign(:attach_network, network)
     |> assign(:identity_suggestions, suggestions)
     |> assign(:filtered_suggestions, filter_suggestions(suggestions, identity, network))
     |> assign(
       :attach_form,
       to_form(%{
         "group_id" => socket.assigns.attach_group_id,
         "network" => network,
         "identity" => identity
       })
     )}
  end

  def handle_event("pick_suggestion", %{"ref" => ref}, socket) do
    network = socket.assigns.attach_network
    display_ref = format_identity_ref(network, ref)

    {:noreply,
     socket
     |> assign(
       :filtered_suggestions,
       filter_suggestions(socket.assigns.identity_suggestions, display_ref, network)
     )
     |> assign(
       :attach_form,
       to_form(%{
         "group_id" => socket.assigns.attach_group_id,
         "network" => network,
         "identity" => display_ref
       })
     )}
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
         |> assign(:modal, nil)
         |> assign(:selected_bridge_id, group.id)
         |> refresh()}

      {:error, :identity_already_linked} ->
        {:noreply, put_flash(socket, :error, "Identity already linked to another group.")}

      {:error, :not_a_bridge_group} ->
        {:noreply, put_flash(socket, :error, "Not a group that can attach members.")}

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

  def handle_event("unlink_channel", %{"network" => "meshcore", "group_id" => group_id}, socket) do
    unlink_radio_channel(socket, group_id, &Registrations.unlink_meshcore_channel/1, "MeshCore")
  end

  def handle_event("unlink_channel", %{"network" => "meshtastic", "group_id" => group_id}, socket) do
    unlink_radio_channel(
      socket,
      group_id,
      &Registrations.unlink_meshtastic_channel/1,
      "Meshtastic"
    )
  end

  defp refresh(socket) do
    all_groups = Registrations.list_all()
    revoked_count = Enum.count(all_groups, &(&1.status == "revoked"))

    groups =
      if socket.assigns.show_revoked do
        all_groups
      else
        Enum.reject(all_groups, &(&1.status == "revoked"))
      end

    bridges = Enum.filter(all_groups, &(&1.kind == "bridge" and &1.status == "active"))

    selected =
      Enum.find(bridges, &(&1.id == socket.assigns.selected_bridge_id)) || List.first(bridges)

    socket
    |> assign(:groups, groups)
    |> assign(:revoked_count, revoked_count)
    |> assign(:bridges, bridges)
    |> assign(:selected_bridge, selected)
    |> assign(:selected_bridge_id, selected && selected.id)
  end

  @suggestion_limit 20

  # Filter recently-heard addresses by the typed query (matches name or ref),
  # so the combobox narrows as the admin types. Empty query shows the newest.
  defp filter_suggestions(suggestions, query, network) do
    q = query |> to_string() |> String.trim() |> String.downcase()

    suggestions
    |> Enum.filter(fn s ->
      display =
        format_identity_ref(network, s.ref)
        |> to_string()
        |> String.downcase()

      q == "" or
        String.contains?(String.downcase(to_string(s.ref)), q) or
        String.contains?(display, q) or
        (is_binary(s.name) and String.contains?(String.downcase(s.name), q))
    end)
    |> Enum.take(@suggestion_limit)
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

  defp unlink_radio_channel(socket, group_id, unlink_fun, label) do
    group = Registrations.get_group!(group_id)

    case unlink_fun.(group) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "#{label} channel unlinked.")
         |> refresh()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Unlink failed: #{inspect(reason)}")}
    end
  end

  defp presence_chips(group) do
    identity =
      Enum.map(group.legs || [], fn leg ->
        %{
          id: "chip-leg-#{leg.id}",
          label: "#{leg.network}/#{leg.role}",
          class: "badge-ghost"
        }
      end)

    channels =
      []
      |> maybe_channel_chip(group.meshcore_channel_idx, "meshcore", "badge-primary")
      |> maybe_channel_chip(group.meshtastic_channel_idx, "meshtastic", "badge-accent")

    identity ++ channels
  end

  defp maybe_channel_chip(chips, nil, _network, _class), do: chips

  defp maybe_channel_chip(chips, idx, network, class) when is_integer(idx) do
    chips ++
      [
        %{
          id: "chip-#{network}-ch",
          label: "#{network}/ch #{idx}",
          class: class
        }
      ]
  end

  defp member_rows(group) do
    identity =
      Enum.map(group.legs || [], fn leg ->
        {label, class, hint} = identity_role_copy(leg.role)

        %{
          id: "member-#{leg.id}",
          network: leg.network,
          identity: format_identity_ref(leg.network, leg.identity_ref),
          title: leg.identity_ref,
          kind: :identity,
          leg_id: leg.id,
          detachable?: leg.role == "member",
          role_label: label,
          role_class: class,
          role_hint: hint
        }
      end)

    channels =
      []
      |> maybe_channel_row(group, :meshcore, group.meshcore_channel_idx, ~p"/admin/meshcore")
      |> maybe_channel_row(
        group,
        :meshtastic,
        group.meshtastic_channel_idx,
        ~p"/admin/meshtastic"
      )

    identity ++ channels
  end

  defp identity_role_copy("proxy") do
    {"proxy", "badge-info",
     "Isthmus-owned identity. Announced from this node; peers message this."}
  end

  defp identity_role_copy("member") do
    {"external", "badge-ghost",
     "Attached peer. Isthmus delivers to this identity; it is not announced from here."}
  end

  defp identity_role_copy("primary") do
    {"primary", "badge-primary", "Your own identity on this network."}
  end

  defp identity_role_copy(role) do
    {role || "unknown", "badge-ghost", ""}
  end

  defp maybe_channel_row(rows, _group, _network, nil, _href), do: rows

  defp maybe_channel_row(rows, group, network, idx, href) when is_integer(idx) do
    net = Atom.to_string(network)

    rows ++
      [
        %{
          id: "member-channel-#{net}",
          network: net,
          identity: "channel slot #{idx}",
          title: nil,
          kind: :channel,
          unlink_network: net,
          group_id: group.id,
          href: href,
          role_label: "channel",
          role_class: "badge-ghost",
          role_hint: "Private radio channel linked to this group."
        }
      ]
  end

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
              Groups attach real identities across networks. Private radio channels are
              configured under <.link navigate={~p"/admin/meshcore"} class="link">MeshCore</.link>
              and <.link navigate={~p"/admin/meshtastic"} class="link">Meshtastic</.link>.
            </p>
          </div>
          <.admin_nav current={:groups} />
        </div>

        <div class="flex flex-wrap items-center gap-2">
          <button class="btn btn-primary btn-sm" phx-click="open_new_group" type="button">
            <.icon name="hero-plus" class="w-4 h-4" /> New group
          </button>
          <span class="text-xs opacity-60">
            Attach members from each group's row below.
          </span>
        </div>

        <div :if={@selected_bridge} class="space-y-3">
          <h2 class="text-xl font-medium">
            {@selected_bridge.display_name}
            <span class="badge badge-secondary badge-sm ml-2">group</span>
          </h2>
          <p class="text-sm opacity-70">
            MeshCore address token: <code class="font-mono">@{token_for(@selected_bridge)}</code>
          </p>
          <p class="text-xs opacity-60">
            <strong class="font-medium">Proxy</strong>
            identities are minted and announced by Isthmus.
            <strong class="font-medium">External</strong>
            identities are attached peers Isthmus sends to.
          </p>
          <div class="overflow-x-auto">
            <table class="table table-sm" id="bridge-members-table">
              <thead>
                <tr>
                  <th>Network</th>
                  <th>Role</th>
                  <th>Identity</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <tr :for={row <- member_rows(@selected_bridge)} id={row.id}>
                  <td class="capitalize">{row.network}</td>
                  <td>
                    <span
                      id={"#{row.id}-role"}
                      class={["badge badge-sm", row.role_class]}
                      title={row.role_hint}
                    >
                      {row.role_label}
                    </span>
                  </td>
                  <td
                    class="font-mono text-xs break-all"
                    title={row.title}
                  >
                    {row.identity}
                  </td>
                  <td>
                    <div class="flex flex-wrap gap-1 justify-end">
                      <%= if row.kind == :identity do %>
                        <button
                          :if={row.detachable?}
                          class="btn btn-ghost btn-xs text-error"
                          phx-click="detach_member"
                          phx-value-leg_id={row.leg_id}
                          phx-value-group_id={@selected_bridge.id}
                        >
                          Detach
                        </button>
                      <% else %>
                        <.link navigate={row.href} class="btn btn-ghost btn-xs">
                          Invite
                        </.link>
                        <button
                          class="btn btn-ghost btn-xs text-error"
                          id={"unlink-#{row.unlink_network}-channel-btn"}
                          phx-click="unlink_channel"
                          phx-value-network={row.unlink_network}
                          phx-value-group_id={row.group_id}
                        >
                          Unlink
                        </button>
                      <% end %>
                    </div>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <div>
          <div class="mb-3 flex flex-wrap items-center justify-between gap-2">
            <h2 class="text-xl font-medium">All groups</h2>
            <button
              type="button"
              id="toggle-show-revoked"
              class={[
                "btn btn-ghost btn-xs",
                @show_revoked && "btn-active"
              ]}
              phx-click="toggle_show_revoked"
            >
              <%= if @show_revoked do %>
                Hide revoked
              <% else %>
                Show revoked{if(@revoked_count > 0, do: " (#{@revoked_count})", else: "")}
              <% end %>
            </button>
          </div>
          <div class="overflow-x-auto">
            <table class="table" id="groups-table">
              <thead>
                <tr>
                  <th>Kind</th>
                  <th>Owner</th>
                  <th>Name</th>
                  <th>Status</th>
                  <th>Legs</th>
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
                      {AdminCopy.group_kind_label(group.kind)}
                    </span>
                  </td>
                  <td
                    class="font-mono text-xs break-all max-w-xs"
                    title={group.owner_pubkey_hex}
                  >
                    {format_npub(group.owner_pubkey_hex)}
                  </td>
                  <td>{group.display_name}</td>
                  <td><span class="badge">{group.status}</span></td>
                  <td>
                    <div class="flex flex-wrap gap-1">
                      <span class="hidden only:block opacity-50">—</span>
                      <span
                        :for={chip <- presence_chips(group)}
                        id={"group-#{group.id}-#{chip.id}"}
                        class={["badge badge-sm capitalize", chip.class]}
                      >
                        {chip.label}
                      </span>
                    </div>
                  </td>
                  <td>
                    <div class="flex flex-wrap gap-1 justify-end">
                      <button
                        :if={group.kind == "bridge" and group.status == "active"}
                        class="btn btn-primary btn-xs"
                        phx-click="open_attach"
                        phx-value-id={group.id}
                      >
                        Attach member
                      </button>
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

        <%!-- New group modal --%>
        <div :if={@modal == :new_group} class="modal modal-open" role="dialog" id="new-group-modal">
          <div class="modal-box">
            <h3 class="text-lg font-semibold">New group</h3>
            <p class="mt-1 text-sm opacity-70">
              Groups mint proxies and attach real identities across networks.
            </p>
            <.form
              for={@bridge_form}
              id="bridge-create-form"
              phx-submit="create_bridge"
              class="mt-4 space-y-4"
            >
              <.input
                field={@bridge_form[:display_name]}
                type="text"
                label="Display name"
                placeholder="Lobby"
              />
              <div class="modal-action">
                <button class="btn btn-ghost btn-sm" phx-click="close_modal" type="button">
                  Cancel
                </button>
                <button class="btn btn-primary btn-sm" type="submit">Create</button>
              </div>
            </.form>
          </div>
          <div class="modal-backdrop" phx-click="close_modal"></div>
        </div>

        <%!-- Attach member modal --%>
        <div :if={@modal == :attach} class="modal modal-open" role="dialog" id="attach-member-modal">
          <div class="modal-box">
            <h3 class="text-lg font-semibold">
              Attach member
              <span :if={@attach_group_name} class="opacity-60 font-normal">
                → {@attach_group_name}
              </span>
            </h3>
            <.form
              for={@attach_form}
              id="bridge-attach-form"
              phx-submit="attach_member"
              phx-change="attach_form_changed"
              class="mt-4 space-y-4"
            >
              <input type="hidden" name="group_id" value={@attach_group_id} />
              <.input
                field={@attach_form[:network]}
                type="select"
                label="Network"
                options={[
                  {"MeshCore", "meshcore"},
                  {"Reticulum", "reticulum"},
                  {"Nostr", "nostr"}
                ]}
              />
              <div>
                <.input
                  field={@attach_form[:identity]}
                  type="text"
                  label="Identity"
                  placeholder="npub / MeshCore pubkey / RNS dest hash"
                  autocomplete="off"
                  phx-debounce="150"
                />
                <div :if={@attach_network in ["meshcore", "reticulum"]} class="mt-2">
                  <p class="text-xs opacity-60 mb-1">
                    <%= if @identity_suggestions == [] do %>
                      No {@attach_network} adverts heard in the last 24h.
                      <.link navigate={~p"/admin/adverts"} class="link">See Adverts →</.link>
                    <% else %>
                      Heard on {@attach_network} in the last 24h — click to fill:
                    <% end %>
                  </p>
                  <ul
                    :if={@filtered_suggestions != []}
                    class="menu menu-sm bg-base-100 rounded-box border border-base-300 max-h-52 flex-nowrap overflow-y-auto p-1"
                    id="identity-suggestions"
                  >
                    <li :for={s <- @filtered_suggestions} id={"suggestion-#{s.ref}"}>
                      <button
                        type="button"
                        phx-click="pick_suggestion"
                        phx-value-ref={s.ref}
                        class="flex flex-col items-start gap-0"
                      >
                        <span class="text-sm">{s.name || "(unnamed)"}</span>
                        <span class="font-mono text-[10px] opacity-60 break-all" title={s.ref}>
                          {format_identity_ref(@attach_network, s.ref)}
                        </span>
                      </button>
                    </li>
                  </ul>
                </div>
              </div>
              <div class="modal-action">
                <button class="btn btn-ghost btn-sm" phx-click="close_modal" type="button">
                  Cancel
                </button>
                <button class="btn btn-primary btn-sm" type="submit">Attach</button>
              </div>
            </.form>
          </div>
          <div class="modal-backdrop" phx-click="close_modal"></div>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
