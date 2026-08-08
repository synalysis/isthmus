defmodule IsthmusWeb.Admin.MeshCoreLive do
  use IsthmusWeb, :live_view

  alias Isthmus.Networks.MeshCore.BridgeCLI
  alias Isthmus.Networks.MeshCore.BridgeLink
  alias Isthmus.Networks.MeshCore.Companion
  alias Isthmus.Networks.MeshCore.Discover
  alias Isthmus.Networks.MeshCore.RadioParams
  alias Isthmus.Networks.MeshCore.SyntheticNode
  alias Isthmus.QR
  alias Isthmus.Registrations

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Isthmus.PubSub, "meshcore:channels")
      :timer.send_interval(5_000, self(), :refresh_synthetic)
    end

    {:ok,
     socket
     |> assign(:page_title, "MeshCore")
     |> assign(:channel_syncing, false)
     |> assign(:channel_invite, nil)
     |> assign(:selected_bridge_id, nil)
     |> assign(:radio_applying, false)
     |> assign(:synthetic_health, %{status: :unknown, identities: []})
     |> assign(:channel_bridge_form, to_form(%{"display_name" => ""}))
     |> assign(:channel_link_form, to_form(%{"group_id" => "", "channel_idx" => ""}))
     |> assign(:companion_radio_form, to_form(RadioParams.empty_form_params()))
     |> assign(:repeater_radio_form, to_form(RadioParams.empty_form_params()))
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

  def handle_event("rescan_devices", _params, socket) do
    case Discover.refresh() do
      {:ok, roles} ->
        {:noreply,
         socket
         |> put_flash(:info, "Rescanned — #{format_roles_flash(roles)}")
         |> refresh()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Rescan failed: #{inspect(reason)}")}
    end
  end

  def handle_event("save_companion_radio", %{"radio" => params}, socket) do
    case Companion.set_radio_params(params) do
      :ok ->
        case Companion.set_tx_power(params["tx_power"] || params[:tx_power]) do
          :ok ->
            {:noreply,
             socket
             |> put_flash(:info, "Companion radio updated.")
             |> refresh()}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "TX power failed: #{inspect(reason)}")}
        end

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Companion radio failed: #{format_err(reason)}")}
    end
  end

  def handle_event("apply_repeater_radio", %{"radio" => params}, socket) do
    socket = assign(socket, :radio_applying, true)

    case BridgeCLI.apply_and_reboot(params) do
      :ok ->
        {:noreply,
         socket
         |> assign(:radio_applying, false)
         |> put_flash(:info, "Repeater radio applied — rebooting, bridge will reconnect shortly.")
         |> refresh()}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:radio_applying, false)
         |> put_flash(:error, "Repeater radio failed: #{format_err(reason)}")}
    end
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

  def handle_info(:refresh_synthetic, socket) do
    {:noreply, assign(socket, :synthetic_health, SyntheticNode.health())}
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

    companion = Companion.health()
    bridge_cli = BridgeCLI.health()
    roles = Discover.roles()

    socket
    |> assign(:groups, groups)
    |> assign(:bridges, bridges)
    |> assign(:selected_bridge, selected)
    |> assign(:selected_bridge_id, selected && selected.id)
    |> assign(:meshcore_channels, Companion.list_channels())
    |> assign(:companion_health, companion)
    |> assign(:bridge_health, BridgeLink.health())
    |> assign(:bridge_cli_health, bridge_cli)
    |> assign(:synthetic_health, SyntheticNode.health())
    |> assign(:discovered_roles, roles)
    |> assign(:companion_radio_form, to_form(radio_form_from_health(companion), as: :radio))
    |> assign(:repeater_radio_form, to_form(radio_form_from_health(bridge_cli), as: :radio))
    |> assign(:channel_syncing, socket.assigns[:channel_syncing] || false)
    |> assign(:radio_applying, socket.assigns[:radio_applying] || false)
  end

  defp radio_form_from_health(health) when is_map(health) do
    if health[:freq_mhz] do
      RadioParams.to_form_params(health)
    else
      RadioParams.empty_form_params()
    end
  end

  defp radio_form_from_health(_), do: RadioParams.empty_form_params()

  defp format_err(reason) when is_binary(reason), do: reason
  defp format_err(reason), do: inspect(reason)

  defp format_roles_flash(roles) when map_size(roles) == 0, do: "no MeshCore devices found"

  defp format_roles_flash(roles) do
    roles
    |> Enum.map(fn {role, %{path: path}} -> "#{role} @ #{path}" end)
    |> Enum.join(", ")
  end

  defp bridge_badge(:online), do: "badge-success"
  defp bridge_badge(:disabled), do: "badge-ghost"
  defp bridge_badge(_), do: "badge-warning"

  attr :form, :any, required: true
  attr :id_prefix, :string, required: true

  defp radio_fields(assigns) do
    ~H"""
    <div class="grid grid-cols-2 gap-3 sm:grid-cols-3">
      <.input
        field={@form[:freq_mhz]}
        type="text"
        label="Freq (MHz)"
        id={"#{@id_prefix}-freq"}
      />
      <.input field={@form[:bw_khz]} type="text" label="BW (kHz)" id={"#{@id_prefix}-bw"} />
      <.input field={@form[:sf]} type="number" label="SF" min="5" max="12" id={"#{@id_prefix}-sf"} />
      <.input field={@form[:cr]} type="number" label="CR" min="5" max="8" id={"#{@id_prefix}-cr"} />
      <.input
        field={@form[:tx_power]}
        type="number"
        label="TX (dBm)"
        min="0"
        max="22"
        id={"#{@id_prefix}-tx"}
      />
    </div>
    """
  end

  defp short_key(hex) when is_binary(hex) and byte_size(hex) > 12 do
    String.slice(hex, 0, 8) <> "…" <> String.slice(hex, -4, 4)
  end

  defp short_key(hex), do: hex

  defp format_age(%DateTime{} = at) do
    case DateTime.diff(DateTime.utc_now(), at) do
      s when s < 2 -> "just now"
      s when s < 60 -> "#{s}s ago"
      s when s < 3_600 -> "#{div(s, 60)}m ago"
      s -> "#{div(s, 3_600)}h ago"
    end
  end

  defp format_age(_), do: "never"

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
          <span class={["badge", bridge_badge(@bridge_cli_health[:status])]} id="bridge-cli-badge">
            repeater CLI {@bridge_cli_health[:status]}
          </span>
          <span class={["badge", bridge_badge(@bridge_health[:status])]} id="bridge-status-badge">
            bridge {@bridge_health[:status]}
          </span>
          <span
            class={["badge", bridge_badge(@synthetic_health[:status])]}
            id="synthetic-status-badge"
          >
            synthetics {@synthetic_health[:identity_count] || 0}
          </span>
          <button
            class="btn btn-outline btn-sm"
            phx-click="rescan_devices"
            id="rescan-devices-btn"
          >
            Rescan devices
          </button>
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

        <div class="card bg-base-200 border border-base-300" id="detected-devices-card">
          <div class="card-body space-y-2 py-4">
            <h2 class="card-title text-base">Detected devices</h2>
            <%= if map_size(@discovered_roles) == 0 do %>
              <p class="text-sm opacity-70">
                No MeshCore companion or bridge repeater found. Plug in a USB radio and
                Rescan, or set port overrides in the environment.
              </p>
            <% else %>
              <ul class="text-sm space-y-1 font-mono">
                <%= for {role, %{path: path, source: source}} <- @discovered_roles do %>
                  <li id={"detected-#{role}"}>
                    <span class="opacity-60">{role}</span>
                    {path}
                    <span class="badge badge-ghost badge-sm">{source}</span>
                  </li>
                <% end %>
              </ul>
            <% end %>
          </div>
        </div>

        <div class="card bg-base-200 border border-base-300" id="bridge-card">
          <div class="card-body space-y-3">
            <div class="flex flex-wrap items-start justify-between gap-3">
              <div>
                <h2 class="card-title text-lg">Island bridge</h2>
                <p class="text-xs opacity-70">
                  Raw packet stream from a bridge-enabled repeater. Carries a whole MeshCore
                  island over a tunnel, adverts and DMs alike.
                </p>
              </div>
              <span class={["badge", bridge_badge(@bridge_health[:status])]}>
                {@bridge_health[:status]}
              </span>
            </div>

            <%= if @bridge_health[:status] == :disabled do %>
              <p class="text-sm opacity-70">
                No packet port detected. Isthmus looks for the sibling CDC of a bridge
                repeater CLI, or you can pin <code>ISTHMUS_MESHCORE_BRIDGE_PORT</code>.
              </p>
            <% else %>
              <dl class="grid grid-cols-2 gap-x-6 gap-y-2 text-sm sm:grid-cols-3">
                <div>
                  <dt class="text-xs uppercase opacity-60">Port</dt>
                  <dd class="font-mono text-xs">{@bridge_health[:port] || "—"}</dd>
                </div>
                <div>
                  <dt class="text-xs uppercase opacity-60">Frames in</dt>
                  <dd class="font-mono">{@bridge_health[:frames_in] || 0}</dd>
                </div>
                <div>
                  <dt class="text-xs uppercase opacity-60">Frames out</dt>
                  <dd class="font-mono">{@bridge_health[:frames_out] || 0}</dd>
                </div>
                <div>
                  <dt class="text-xs uppercase opacity-60">Checksum errors</dt>
                  <dd class={[
                    "font-mono",
                    (@bridge_health[:checksum_errors] || 0) > 0 && "text-warning"
                  ]}>
                    {@bridge_health[:checksum_errors] || 0}
                  </dd>
                </div>
                <div>
                  <dt class="text-xs uppercase opacity-60">Resync bytes</dt>
                  <dd class="font-mono">{@bridge_health[:dropped_bytes] || 0}</dd>
                </div>
                <div>
                  <dt class="text-xs uppercase opacity-60">Last packet</dt>
                  <dd class="font-mono text-xs">{format_age(@bridge_health[:last_rx_at])}</dd>
                </div>
              </dl>

              <%= if @bridge_health[:last_error] do %>
                <p class="text-xs text-warning font-mono">{@bridge_health[:last_error]}</p>
              <% end %>
            <% end %>
          </div>
        </div>

        <div class="card bg-base-200 border border-base-300" id="synthetic-identities-card">
          <div class="card-body space-y-3">
            <div class="flex flex-wrap items-start justify-between gap-3">
              <div>
                <h2 class="card-title text-lg">Synthetic identities</h2>
                <p class="text-xs opacity-70">
                  Per-group MeshCore contacts announced and spoken via the island bridge.
                </p>
              </div>
              <span class={["badge", bridge_badge(@synthetic_health[:status])]}>
                {@synthetic_health[:status]}
              </span>
            </div>

            <%= if (@synthetic_health[:identities] || []) == [] do %>
              <p class="text-sm opacity-70">
                No MeshCore proxies loaded. Mint contacts from /me or create a bridge with a channel.
              </p>
            <% else %>
              <div class="overflow-x-auto">
                <table class="table table-sm" id="synthetic-identities-table">
                  <thead>
                    <tr>
                      <th>Name</th>
                      <th>Pubkey</th>
                      <th>Paths</th>
                      <th>Last RX</th>
                      <th>Last TX</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr
                      :for={id <- @synthetic_health[:identities] || []}
                      id={"synthetic-#{id.public_key}"}
                    >
                      <td>{id.name}</td>
                      <td class="font-mono text-xs">{short_key(id.public_key)}</td>
                      <td class="font-mono">{id.path_peers}</td>
                      <td class="font-mono text-xs">{format_age(id.last_rx_at)}</td>
                      <td class="font-mono text-xs">{format_age(id.last_tx_at)}</td>
                    </tr>
                  </tbody>
                </table>
              </div>
            <% end %>
          </div>
        </div>

        <div class="grid gap-6 lg:grid-cols-2">
          <%= if @companion_health.status in [:online, :disconnected, :error] and @companion_health[:port] do %>
            <div class="card bg-base-200 border border-base-300" id="companion-radio-card">
              <div class="card-body space-y-3">
                <div>
                  <h2 class="card-title text-lg">Companion radio</h2>
                  <p class="text-xs opacity-70">
                    Frequency settings for the USB companion
                    (<span class="font-mono">{@companion_health[:port]}</span>).
                  </p>
                </div>
                <.form
                  for={@companion_radio_form}
                  id="companion-radio-form"
                  phx-submit="save_companion_radio"
                  class="space-y-3"
                >
                  <.radio_fields form={@companion_radio_form} id_prefix="companion" />
                  <button
                    class="btn btn-primary btn-sm"
                    type="submit"
                    id="save-companion-radio-btn"
                    disabled={@companion_health.status != :online}
                  >
                    Save
                  </button>
                </.form>
              </div>
            </div>
          <% end %>

          <%= if @bridge_cli_health[:port] && @bridge_cli_health[:status] != :disabled do %>
            <div class="card bg-base-200 border border-base-300" id="repeater-radio-card">
              <div class="card-body space-y-3">
                <div>
                  <h2 class="card-title text-lg">Repeater radio</h2>
                  <p class="text-xs opacity-70">
                    Permanent settings for the bridge repeater CLI
                    (<span class="font-mono">{@bridge_cli_health[:port]}</span>).
                    Apply reboots the radio — the packet bridge drops briefly.
                  </p>
                </div>
                <.form
                  for={@repeater_radio_form}
                  id="repeater-radio-form"
                  phx-submit="apply_repeater_radio"
                  class="space-y-3"
                >
                  <.radio_fields form={@repeater_radio_form} id_prefix="repeater" />
                  <button
                    class={["btn btn-primary btn-sm", @radio_applying && "loading"]}
                    type="submit"
                    id="apply-repeater-radio-btn"
                    disabled={@bridge_cli_health[:status] != :online or @radio_applying}
                  >
                    {if(@radio_applying, do: "Applying…", else: "Apply & reboot")}
                  </button>
                </.form>
              </div>
            </div>
          <% end %>
        </div>

        <%= if @companion_health.status != :online do %>
          <div class="alert alert-warning">
            Companion offline. Plug in a companion radio and Rescan, or set <code>ISTHMUS_MESHCORE_PORT</code>.
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
