defmodule IsthmusWeb.Admin.MeshCoreLive do
  use IsthmusWeb, :live_view

  alias Isthmus.Networks.MeshCore.BridgeCLI
  alias Isthmus.Networks.MeshCore.BridgeLink
  alias Isthmus.Networks.MeshCore.Companion
  alias Isthmus.Networks.MeshCore.Devices
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
           "Group + private MeshCore channel created (slot #{group.meshcore_channel_idx})."
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

  def handle_event("validate_companion_radio", %{"radio" => params} = payload, socket) do
    params = RadioParams.apply_form_change(params, payload["_target"])

    {:noreply, assign(socket, :companion_radio_form, to_form(params, as: :radio))}
  end

  def handle_event("validate_repeater_radio", %{"radio" => params} = payload, socket) do
    params = RadioParams.apply_form_change(params, payload["_target"])

    {:noreply, assign(socket, :repeater_radio_form, to_form(params, as: :radio))}
  end

  def handle_event("save_companion_radio", %{"radio" => params} = payload, socket) do
    device_id = payload["device_id"]

    with :ok <- ensure_device_role(socket, device_id, :companion),
         :ok <- Companion.set_radio_params(params),
         :ok <- Companion.set_tx_power(params["tx_power"] || params[:tx_power]) do
      {:noreply,
       socket
       |> put_flash(:info, "Companion radio updated on #{device_label(socket, device_id)}.")
       |> refresh()}
    else
      {:error, :unknown_device} ->
        {:noreply, put_flash(socket, :error, "Unknown device — rescan USB and try again.")}

      {:error, :wrong_role} ->
        {:noreply, put_flash(socket, :error, "That device is not the active companion.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Companion radio failed: #{format_err(reason)}")}
    end
  end

  def handle_event("apply_repeater_radio", %{"radio" => params} = payload, socket) do
    device_id = payload["device_id"]
    socket = assign(socket, :radio_applying, true)

    with :ok <- ensure_device_role(socket, device_id, :bridge_cli),
         :ok <- BridgeCLI.apply_and_reboot(params) do
      {:noreply,
       socket
       |> assign(:radio_applying, false)
       |> put_flash(
         :info,
         "Repeater radio applied on #{device_label(socket, device_id)} — rebooting, bridge will reconnect shortly."
       )
       |> refresh()}
    else
      {:error, :unknown_device} ->
        {:noreply,
         socket
         |> assign(:radio_applying, false)
         |> put_flash(:error, "Unknown device — rescan USB and try again.")}

      {:error, :wrong_role} ->
        {:noreply,
         socket
         |> assign(:radio_applying, false)
         |> put_flash(:error, "That device is not the active bridge repeater.")}

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
    bridge_link = BridgeLink.health()
    roles = Discover.roles()

    devices =
      Devices.inventory(
        roles: roles,
        companion: companion,
        bridge_cli: bridge_cli,
        bridge_link: bridge_link
      )

    socket
    |> assign(:groups, groups)
    |> assign(:bridges, bridges)
    |> assign(:selected_bridge, selected)
    |> assign(:selected_bridge_id, selected && selected.id)
    |> assign(:meshcore_channels, Companion.list_channels())
    |> assign(:companion_health, companion)
    |> assign(:bridge_health, bridge_link)
    |> assign(:bridge_cli_health, bridge_cli)
    |> assign(:synthetic_health, SyntheticNode.health())
    |> assign(:discovered_roles, roles)
    |> assign(:devices, devices)
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

  defp ensure_device_role(socket, device_id, role) do
    case Enum.find(socket.assigns[:devices] || [], &(&1.id == device_id)) do
      nil ->
        {:error, :unknown_device}

      device ->
        ok? =
          case role do
            :companion -> device.companion? and device.active_companion?
            :bridge_cli -> device.bridge_cli? and device.active_bridge_cli?
            _ -> false
          end

        if ok?, do: :ok, else: {:error, :wrong_role}
    end
  end

  defp device_label(socket, device_id) do
    case Enum.find(socket.assigns[:devices] || [], &(&1.id == device_id)) do
      %{label: label} when is_binary(label) and label != "" -> label
      _ -> device_id || "device"
    end
  end

  defp device_dom_id(id) when is_binary(id) do
    "device-" <> String.replace(id, ~r/[^A-Za-z0-9_-]/, "-")
  end

  defp port_dom_key(path) when is_binary(path) do
    path |> Path.basename() |> String.replace(~r/[^A-Za-z0-9_-]/, "-")
  end

  defp port_dom_key(_), do: "unknown"

  defp port_status(device, :companion) do
    cond do
      device.active_companion? ->
        :online

      device.companion? and is_map(device.companion_health) ->
        device.companion_health[:status] || :disconnected

      device.companion? ->
        :disconnected

      true ->
        nil
    end
  end

  defp port_status(device, :bridge_cli) do
    cond do
      device.active_bridge_cli? ->
        :online

      device.bridge_cli? and is_map(device.bridge_cli_health) ->
        device.bridge_cli_health[:status] || :disconnected

      device.bridge_cli? ->
        :disconnected

      true ->
        nil
    end
  end

  defp port_status(device, :bridge_packet) do
    cond do
      device.active_bridge_link? ->
        :online

      device.bridge_packet? and is_map(device.bridge_link_health) ->
        device.bridge_link_health[:status] || :disconnected

      device.bridge_packet? ->
        :disconnected

      true ->
        nil
    end
  end

  defp port_status(_, _), do: nil

  defp tunnel_radio(devices) do
    Enum.find(devices, &(&1.bridge_packet? or &1.kind == :bridge_repeater))
  end

  defp island_status_atom(bridge_health) do
    case bridge_health[:status] do
      :online -> :online
      :disabled -> :disabled
      nil -> :disabled
      other -> other
    end
  end

  defp usb_id_line(device) do
    parts =
      [
        if(is_integer(device.vendor_id) and is_integer(device.product_id),
          do: "#{hex4(device.vendor_id)}:#{hex4(device.product_id)}"
        ),
        device.serial_number && "S/N #{device.serial_number}"
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(parts, " · ")
  end

  defp hex4(n) when is_integer(n),
    do: n |> Integer.to_string(16) |> String.pad_leading(4, "0") |> String.downcase()

  attr :form, :any, required: true
  attr :id_prefix, :string, required: true

  defp radio_fields(assigns) do
    ~H"""
    <div class="space-y-3">
      <.input
        field={@form[:preset]}
        type="select"
        label="Preset"
        options={RadioParams.preset_options()}
        id={"#{@id_prefix}-preset"}
      />
      <p class="text-xs opacity-70 -mt-1">
        Same community presets as the MeshCore app. Custom keeps the fields below.
      </p>
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
    tunnel = tunnel_radio(assigns.devices)
    island_atom = island_status_atom(assigns.bridge_health)

    assigns =
      assigns
      |> assign(:tunnel_radio, tunnel)
      |> assign(:island_status, island_atom)

    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <section class="space-y-10">
        <.admin_header current={:meshcore} title="MeshCore">
          Connect radios here. An <strong class="font-medium">island tunnel radio</strong>
          carries mesh traffic for tunnels; a <strong class="font-medium">companion radio</strong>
          links private channels to groups.
        </.admin_header>

        <%!-- 1. Connected radios --%>
        <div class="space-y-4" id="connected-radios">
          <div class="flex flex-wrap items-start justify-between gap-3">
            <div>
              <h2 class="text-lg font-medium">Connected radios</h2>
              <p class="text-xs opacity-70 mt-1">
                What each USB radio is for. Controls stay on the radio they belong to.
              </p>
            </div>
            <div class="flex flex-wrap items-center gap-3">
              <button
                class="btn btn-outline btn-sm"
                phx-click="rescan_devices"
                id="rescan-devices-btn"
              >
                Rescan USB
              </button>
              <.link navigate={~p"/admin/registrations"} class="link link-hover text-sm">
                Manage group members →
              </.link>
            </div>
          </div>

          <%= if @devices == [] do %>
            <div class="rounded-lg border border-base-300 bg-base-200/50 p-4" id="devices-empty">
              <p class="text-sm opacity-70">
                No MeshCore radios found. Plug in a companion and/or island tunnel radio, then Rescan.
              </p>
              <details class="mt-2 text-xs opacity-60">
                <summary class="cursor-pointer">Technical details</summary>
                <p class="mt-1 font-mono">
                  ISTHMUS_MESHCORE_PORT · ISTHMUS_MESHCORE_BRIDGE_CLI_PORT · ISTHMUS_MESHCORE_BRIDGE_PORT
                </p>
              </details>
            </div>
          <% end %>

          <div
            :for={device <- @devices}
            class="card bg-base-200 border border-base-300"
            id={device_dom_id(device.id)}
            data-device-id={device.id}
          >
            <% {purpose_title, purpose_blurb} = AdminCopy.device_purpose(device) %>
            <% {status_atom, status_text} = AdminCopy.device_status(device) %>
            <div class="card-body space-y-5">
              <div class="flex flex-wrap items-start justify-between gap-3">
                <div class="min-w-0 space-y-1">
                  <div class="flex flex-wrap items-center gap-2">
                    <h3 class="card-title text-lg">{device.label}</h3>
                    <span class="badge badge-sm badge-outline">{purpose_title}</span>
                    <span class={["badge badge-sm", AdminCopy.status_badge_class(status_atom)]}>
                      {status_text}
                    </span>
                  </div>
                  <p class="text-sm opacity-80">{purpose_blurb}</p>
                  <%= if device.identity && device.identity.name do %>
                    <p class="text-sm">
                      On-air name <span class="font-medium">{device.identity.name}</span>
                      <%= if device.identity.public_key do %>
                        <span class="font-mono text-xs opacity-70 ml-2">
                          {short_key(device.identity.public_key)}
                        </span>
                      <% end %>
                    </p>
                  <% end %>
                  <%= if device.kind == :unknown do %>
                    <p class="text-sm text-warning" id={"#{device_dom_id(device.id)}-identify-hint"}>
                      Isthmus has not identified this radio’s role yet. Power it on and Rescan USB.
                    </p>
                  <% end %>
                </div>
              </div>

              <div class="overflow-x-auto">
                <table class="table table-sm" id={"#{device_dom_id(device.id)}-ports"}>
                  <thead>
                    <tr>
                      <th>Port role</th>
                      <th>Status</th>
                      <th>Used for</th>
                      <th></th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr
                      :for={port <- device.ports}
                      id={"#{device_dom_id(device.id)}-port-#{port_dom_key(port.path)}"}
                    >
                      <td class="font-medium">{AdminCopy.role_plain(port.role)}</td>
                      <td>
                        <%= if st = port_status(device, port.role) do %>
                          <span class={["badge badge-sm", AdminCopy.status_badge_class(st)]}>
                            {AdminCopy.status_plain(st)}
                          </span>
                        <% else %>
                          <span class="badge badge-sm badge-ghost">Not identified</span>
                        <% end %>
                      </td>
                      <td class="text-sm opacity-80">{AdminCopy.role_used_for(port.role)}</td>
                      <td class="text-right">
                        <%= if port.role == :companion do %>
                          <button
                            class={["btn btn-outline btn-xs", @channel_syncing && "loading"]}
                            phx-click="sync_meshcore_channels"
                            phx-value-device-id={device.id}
                            id={"sync-channels-btn-#{device_dom_id(device.id)}"}
                            disabled={@channel_syncing or not device.active_companion?}
                          >
                            {if(@channel_syncing, do: "Syncing…", else: "Sync channels")}
                          </button>
                        <% end %>
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>

              <details class="text-xs opacity-70" id={"#{device_dom_id(device.id)}-tech"}>
                <summary class="cursor-pointer font-medium opacity-90">Technical details</summary>
                <dl class="mt-2 grid gap-1 sm:grid-cols-2">
                  <div>
                    <dt class="uppercase opacity-60">Device id</dt>
                    <dd class="font-mono break-all">{device.id}</dd>
                  </div>
                  <%= if usb_id_line(device) != "" do %>
                    <div>
                      <dt class="uppercase opacity-60">USB</dt>
                      <dd class="font-mono">{usb_id_line(device)}</dd>
                    </div>
                  <% end %>
                  <div :for={port <- device.ports} class="sm:col-span-2">
                    <dt class="uppercase opacity-60">{AdminCopy.role_plain(port.role)}</dt>
                    <dd class="font-mono">{port.path}</dd>
                  </div>
                </dl>
              </details>

              <%= if device.companion? and is_map(device.companion_health) and
                       is_binary(device.companion_health[:port]) do %>
                <div
                  class="space-y-3 rounded-lg border border-base-300 bg-base-100/40 p-4"
                  id={"#{device_dom_id(device.id)}-companion-radio"}
                >
                  <div>
                    <h4 class="font-medium">Radio settings</h4>
                    <p class="text-xs opacity-70">
                      MeshCore app presets, or frequency and TX for this companion radio.
                    </p>
                  </div>
                  <.form
                    for={@companion_radio_form}
                    id={"companion-radio-form-#{device_dom_id(device.id)}"}
                    phx-change="validate_companion_radio"
                    phx-submit="save_companion_radio"
                    class="space-y-3"
                  >
                    <input type="hidden" name="device_id" value={device.id} />
                    <.radio_fields
                      form={@companion_radio_form}
                      id_prefix={"companion-#{device_dom_id(device.id)}"}
                    />
                    <button
                      class="btn btn-primary btn-sm"
                      type="submit"
                      id={"save-companion-radio-btn-#{device_dom_id(device.id)}"}
                      disabled={not device.active_companion?}
                    >
                      Save
                    </button>
                  </.form>
                </div>
              <% end %>

              <%= if device.bridge_cli? and is_map(device.bridge_cli_health) and
                       is_binary(device.bridge_cli_health[:port]) and
                       device.bridge_cli_health[:status] != :disabled do %>
                <div
                  class="space-y-3 rounded-lg border border-base-300 bg-base-100/40 p-4"
                  id={"#{device_dom_id(device.id)}-repeater-radio"}
                >
                  <div>
                    <h4 class="font-medium">Radio settings</h4>
                    <p class="text-xs opacity-70">
                      MeshCore app presets for this island tunnel radio. Apply reboots the radio —
                      mesh traffic drops briefly.
                    </p>
                  </div>
                  <.form
                    for={@repeater_radio_form}
                    id={"repeater-radio-form-#{device_dom_id(device.id)}"}
                    phx-change="validate_repeater_radio"
                    phx-submit="apply_repeater_radio"
                    class="space-y-3"
                  >
                    <input type="hidden" name="device_id" value={device.id} />
                    <.radio_fields
                      form={@repeater_radio_form}
                      id_prefix={"repeater-#{device_dom_id(device.id)}"}
                    />
                    <button
                      class={["btn btn-primary btn-sm", @radio_applying && "loading"]}
                      type="submit"
                      id={"apply-repeater-radio-btn-#{device_dom_id(device.id)}"}
                      disabled={not device.active_bridge_cli? or @radio_applying}
                    >
                      {if(@radio_applying, do: "Applying…", else: "Apply & reboot")}
                    </button>
                  </.form>
                </div>
              <% end %>
            </div>
          </div>
        </div>

        <%!-- 2. Island mesh --%>
        <div class="card bg-base-200 border border-base-300" id="island-mesh">
          <div class="card-body space-y-4">
            <div class="flex flex-wrap items-start justify-between gap-3">
              <div>
                <h2 class="card-title text-lg">Island mesh traffic</h2>
                <p class="text-xs opacity-70 mt-1">
                  Mesh packets carried by the island tunnel radio — used for tunnels and
                  group contacts on the radio mesh.
                  <%= if @tunnel_radio do %>
                    <span class="opacity-90"> · Radio: {@tunnel_radio.label}</span>
                  <% end %>
                </p>
              </div>
              <span class={["badge", AdminCopy.status_badge_class(@island_status)]}>
                {AdminCopy.status_plain(@island_status)}
              </span>
            </div>

            <%= if @bridge_health[:status] == :online do %>
              <dl class="grid grid-cols-2 gap-x-6 gap-y-2 text-sm sm:grid-cols-3">
                <div>
                  <dt class="text-xs uppercase opacity-60">Frames in</dt>
                  <dd class="font-mono">{@bridge_health[:frames_in] || 0}</dd>
                </div>
                <div>
                  <dt class="text-xs uppercase opacity-60">Frames out</dt>
                  <dd class="font-mono">{@bridge_health[:frames_out] || 0}</dd>
                </div>
                <div>
                  <dt class="text-xs uppercase opacity-60">Last packet</dt>
                  <dd class="font-mono text-xs">{format_age(@bridge_health[:last_rx_at])}</dd>
                </div>
              </dl>
              <details class="text-xs opacity-70">
                <summary class="cursor-pointer">Technical details</summary>
                <dl class="mt-2 grid grid-cols-2 gap-2 sm:grid-cols-3">
                  <div>
                    <dt class="uppercase opacity-60">Port</dt>
                    <dd class="font-mono">{@bridge_health[:port] || "—"}</dd>
                  </div>
                  <div>
                    <dt class="uppercase opacity-60">Checksum errors</dt>
                    <dd class="font-mono">{@bridge_health[:checksum_errors] || 0}</dd>
                  </div>
                  <div>
                    <dt class="uppercase opacity-60">Resync bytes</dt>
                    <dd class="font-mono">{@bridge_health[:dropped_bytes] || 0}</dd>
                  </div>
                </dl>
              </details>
            <% else %>
              <p class="text-sm opacity-70" id="island-mesh-offline-hint">
                Offline — connect an <strong class="font-medium">island tunnel radio</strong>
                (bridge-firmware repeater with two USB ports) and Rescan. Tunnels and mesh
                contacts stay quiet until this is Connected.
              </p>
            <% end %>

            <div class="space-y-3 border-t border-base-300 pt-4" id="mesh-contacts">
              <div class="flex flex-wrap items-start justify-between gap-2">
                <div>
                  <h3 class="font-medium">Contacts on the mesh</h3>
                  <p class="text-xs opacity-70 mt-1">
                    Isthmus-owned MeshCore contacts so groups can speak on the radio mesh.
                    They go live when island traffic is Connected — not a separate switch.
                  </p>
                </div>
                <span class={[
                  "badge badge-sm",
                  AdminCopy.status_badge_class(@synthetic_health[:status])
                ]}>
                  {AdminCopy.status_plain(@synthetic_health[:status])}
                </span>
              </div>

              <%= if (@synthetic_health[:identities] || []) == [] do %>
                <p class="text-sm opacity-70">
                  No mesh contacts loaded yet. Create a group with a private channel below, or mint
                  one from /me.
                </p>
              <% else %>
                <div class="overflow-x-auto">
                  <table class="table table-sm" id="mesh-contacts-table">
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
                <%= if @synthetic_health[:status] != :online and @bridge_health[:status] != :online do %>
                  <p class="text-sm opacity-70">
                    Contacts are listed but Offline until island mesh traffic is Connected.
                  </p>
                <% end %>
              <% end %>
            </div>
          </div>
        </div>

        <%!-- 3. Groups and radio channels --%>
        <div class="space-y-4" id="groups-channels">
          <div>
            <h2 class="text-lg font-medium">Groups and radio channels</h2>
            <p class="text-xs opacity-70 mt-1">
              Link a private MeshCore channel on a companion radio to an Isthmus
              <strong class="font-medium">group</strong>
              so members across networks share that channel.
            </p>
          </div>

          <%= if @companion_health.status != :online do %>
            <div
              class="rounded-lg border border-base-300 bg-base-200/50 p-4 space-y-2"
              id="companion-setup-card"
            >
              <p class="text-sm">
                To create or sync private channels, connect a
                <strong class="font-medium">companion radio</strong>
                (separate from the island tunnel radio).
              </p>
              <p class="text-sm opacity-70">
                Membership for groups is managed on <.link
                  navigate={~p"/admin/registrations"}
                  class="link"
                >Groups</.link>.
              </p>
            </div>
          <% else %>
            <div class="grid gap-6 lg:grid-cols-2" id="companion-channel-tools">
              <div class="card bg-base-200 border border-base-300">
                <div class="card-body space-y-3">
                  <h3 class="card-title text-base">New group + private channel</h3>
                  <p class="text-xs opacity-70">
                    Creates a group and provisions a private channel (slots 1–7) on the companion.
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
                      label="Group name"
                      placeholder="Lobby"
                    />
                    <button class="btn btn-primary btn-sm" type="submit">Create</button>
                  </.form>
                </div>
              </div>

              <div class="card bg-base-200 border border-base-300">
                <div class="card-body space-y-3">
                  <h3 class="card-title text-base">Link channel to existing group</h3>
                  <%= if @bridges == [] do %>
                    <p class="text-sm opacity-70">
                      Create a group on
                      <.link navigate={~p"/admin/registrations"} class="link">Groups</.link>
                      first, or use “New group + private channel”.
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
                          <span class="label-text">Group</span>
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
                          <span class="label-text">Private channel slot</span>
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
                    <th>Linked group</th>
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

          <div
            :if={@selected_bridge}
            class="card bg-base-200 border border-base-300"
            id="channel-bridge-detail"
          >
            <div class="card-body space-y-3">
              <div class="flex flex-wrap items-center gap-2">
                <h3 class="text-xl font-medium">{@selected_bridge.display_name}</h3>
                <span class="badge badge-secondary badge-sm">group</span>
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
                  class="space-y-3 rounded-lg border border-base-300 bg-base-100/40 p-4"
                  id="channel-invite-section"
                >
                  <div class="flex flex-wrap items-center gap-2">
                    <p class="text-sm opacity-70 grow">
                      Linked private MeshCore channel · slot {@selected_bridge.meshcore_channel_idx}
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
                      On another MeshCore device: join this private channel, then send a message —
                      Isthmus fans it out to attached group members.
                    </p>

                    <div class="grid gap-4 md:grid-cols-2" id="channel-invite-panel">
                      <div class="space-y-2" id="channel-invite-secret">
                        <h4 class="text-sm font-medium">Secret key</h4>
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
                        <h4 class="text-sm font-medium">QR code</h4>
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
                  This group has no private MeshCore channel linked yet.
                </p>
              <% end %>
            </div>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
