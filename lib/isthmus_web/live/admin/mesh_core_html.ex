defmodule IsthmusWeb.Admin.MeshCoreHTML do
  @moduledoc false
  use IsthmusWeb, :html

  alias Isthmus.Networks.MeshCore.RadioParams
  alias Isthmus.QR
  alias Isthmus.Registrations
  alias IsthmusWeb.Admin.RadioChannels
  alias IsthmusWeb.Admin.UsbRole
  import IsthmusWeb.Admin.UsbRole, only: [usb_role_picker: 1, usb_firmware_picker: 1]
  import IsthmusWeb.Admin.FirmwareOffer, only: [usb_firmware_offer: 1]

  def radio_config_kind(device) do
    cond do
      device.companion? and is_map(device.companion_health) and
          is_binary(device.companion_health[:port]) ->
        :companion

      device.bridge_cli? and is_map(device.bridge_cli_health) and
        is_binary(device.bridge_cli_health[:port]) and
          device.bridge_cli_health[:status] != :disabled ->
        :repeater

      true ->
        nil
    end
  end

  defp radio_config_active?(device, :companion), do: device.active_companion?

  defp radio_config_active?(device, :repeater), do: device.active_bridge_cli?

  defp device_dom_id(id) when is_binary(id) do
    "device-" <> String.replace(id, ~r/[^A-Za-z0-9_-]/, "-")
  end

  defp port_dom_key(path) when is_binary(path) do
    path |> Path.basename() |> String.replace(~r/[^A-Za-z0-9_-]/, "-")
  end

  defp port_dom_key(_), do: "unknown"

  defp companion_port(device) when is_map(device) do
    get_in(device, [:companion_health, :port]) ||
      Enum.find_value(device.ports || [], fn
        %{role: :companion, path: path} when is_binary(path) and path != "" -> path
        _ -> nil
      end)
  end

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

  defp ble_error(%{ble?: true, companion_health: health}) when is_map(health) do
    case health[:last_error] do
      err when is_binary(err) and err != "" -> String.trim(err, "\"")
      _ -> nil
    end
  end

  defp ble_error(_), do: nil

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

  defp slot_role(%{index: 0}), do: "public"

  defp slot_role(%{empty?: true}), do: "empty"

  defp slot_role(_), do: "private"

  defp meshcore_radio_id(device) when is_map(device) do
    Registrations.normalize_radio_id(
      get_in(device, [:identity, :public_key]) ||
        get_in(device, [:companion_health, :self_ref])
    )
  end

  defp channel_rows(channels) do
    by_idx = Map.new(channels || [], &{&1.index, &1})

    Enum.map(0..7, fn i ->
      Map.get(by_idx, i) || %{index: i, name: "", empty?: true}
    end)
  end

  def page(assigns) do
    tunnel = tunnel_radio(assigns.devices)
    island_atom = island_status_atom(assigns.bridge_health)

    assigns =
      assigns
      |> assign(:tunnel_radio, tunnel)
      |> assign(:island_status, island_atom)
      |> assign(
        :ports_modal_device,
        Enum.find(assigns[:devices] || [], &(&1.id == assigns[:ports_modal_id]))
      )

    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <section class="space-y-10">
        <.admin_header current={:meshcore} title="MeshCore">
          Connect radios here. An <strong class="font-medium">island tunnel radio</strong>
          carries mesh traffic for tunnels. On a <strong class="font-medium">companion</strong>,
          slot 0 is public; assign a group to slots 1–7 on this companion’s
          identity. <strong class="font-medium">Invite</strong>
          shows the secret / QR for another MeshCore device.
        </.admin_header>

        <%!-- 1. Connected radios --%>
        <div class="space-y-4" id="connected-radios">
          <div class="flex flex-wrap items-start justify-between gap-3">
            <div>
              <h2 class="text-lg font-medium">Connected radios</h2>
              <p class="text-xs opacity-70 mt-1">
                What each USB radio is for. Choose firmware on the radio —
                Isthmus then classifies config vs mesh traffic.
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
              <button
                class={["btn btn-outline btn-sm", @firmware_catalog_loading && "loading"]}
                phx-click="refresh_firmware_catalog"
                id="refresh-firmware-catalog-btn"
                type="button"
              >
                {if(@firmware_catalog_loading, do: "Firmware list…", else: "Refresh firmware list")}
              </button>
              <button
                class={["btn btn-outline btn-sm", @ble_scanning && "loading"]}
                phx-click="scan_bluetooth"
                id="scan-bluetooth-btn"
                type="button"
                disabled={@ble_busy}
                title={@ble_busy && "Wait for Bluetooth to finish"}
              >
                {if(@ble_scanning, do: "Scanning…", else: "Scan Bluetooth")}
              </button>
              <.link navigate={~p"/admin/registrations"} class="link link-hover text-sm">
                Manage groups →
              </.link>
            </div>
          </div>

          <div
            :if={@ble_scan != [] or @ble_scanning}
            class="rounded-lg border border-base-300 bg-base-200/50 p-4"
            id="ble-scan-results"
          >
            <h3 class="text-sm font-medium">Nearby MeshCore Bluetooth</h3>
            <p class="text-xs opacity-70 mt-1">
              Companion Bluetooth radios (T1000-E default PIN 123456). USB radios stay connected.
              Bluetooth companions come back after a server restart until you Disconnect.
            </p>
            <p :if={@ble_scanning} class="text-sm opacity-70 mt-2">Scanning…</p>
            <div :if={@ble_scan != []} class="mt-3 overflow-x-auto">
              <table class="table table-sm">
                <thead>
                  <tr>
                    <th>Name</th>
                    <th>Address</th>
                    <th>RSSI</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    :for={dev <- @ble_scan}
                    id={"ble-scan-#{port_dom_key(dev.address)}"}
                  >
                    <td class="text-sm">{dev.name || "MeshCore"}</td>
                    <td class="font-mono text-xs">{dev.address}</td>
                    <td class="text-xs opacity-70">{dev.rssi || "—"}</td>
                    <td>
                      <form
                        id={"ble-connect-#{port_dom_key(dev.address)}"}
                        phx-submit="connect_ble"
                        class="flex flex-wrap items-center justify-end gap-2"
                      >
                        <input type="hidden" name="address" value={dev.address} />
                        <.input
                          id={"ble-pin-#{port_dom_key(dev.address)}"}
                          name="pin"
                          type="text"
                          value={@ble_pin}
                          class="input input-sm w-24"
                        />
                        <button
                          class={[
                            "btn btn-primary btn-xs",
                            @ble_connecting == dev.address && "loading"
                          ]}
                          type="submit"
                          disabled={
                            @ble_busy or
                              MapSet.member?(@ble_online_addrs, String.upcase(dev.address || ""))
                          }
                          title={@ble_busy && "Wait for Bluetooth to finish"}
                        >
                          {if(@ble_connecting == dev.address, do: "Connecting…", else: "Connect")}
                        </button>
                      </form>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>

          <%= if @devices == [] do %>
            <div class="rounded-lg border border-base-300 bg-base-200/50 p-4" id="devices-empty">
              <p class="text-sm opacity-70">
                No MeshCore radios found. Plug in a companion and/or island tunnel
                radio, choose a USB role on that port, then Rescan if needed.
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
                    <span :if={device.ble?} class="badge badge-sm badge-info">Bluetooth</span>
                    <span class={["badge badge-sm", AdminCopy.status_badge_class(status_atom)]}>
                      {status_text}
                    </span>
                    <span
                      :if={
                        IsthmusWeb.Admin.FirmwareOffer.newer?(
                          device,
                          @board_by_device,
                          @firmware_catalog
                        )
                      }
                      class="badge badge-sm badge-warning"
                      id={"#{device_dom_id(device.id)}-firmware-update"}
                    >
                      Firmware update
                    </span>
                  </div>
                  <p class="text-sm opacity-80">{purpose_blurb}</p>
                  <p
                    :if={ble_error(device)}
                    class="text-sm text-error"
                    id={"#{device_dom_id(device.id)}-ble-error"}
                  >
                    {ble_error(device)}
                  </p>
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
                  <%= cond do %>
                    <% AdminCopy.bootloader_usb?(device) -> %>
                      <p
                        class="text-sm text-warning"
                        id={"#{device_dom_id(device.id)}-identify-hint"}
                      >
                        USB is the DFU bootloader (T1000-E-BOOT), not a companion port. If this
                        radio runs Companion Bluetooth, use
                        <strong class="font-medium">Scan Bluetooth</strong>
                        — or flash USB Serial Companion.
                      </p>
                    <% AdminCopy.usb_permission_denied?(device) -> %>
                      <p
                        class="text-sm text-warning"
                        id={"#{device_dom_id(device.id)}-identify-hint"}
                      >
                        Isthmus cannot open this USB port (permission denied). The Docker
                        process is not allowed to use serial devices — pass
                        <code class="text-xs">/dev/ttyUSB*</code>
                        into the container and grant the host <code class="text-xs">dialout</code>
                        group, or run the image so the entrypoint can chmod the device.
                      </p>
                    <% device.kind == :unknown -> %>
                      <p
                        class="text-sm text-warning"
                        id={"#{device_dom_id(device.id)}-identify-hint"}
                      >
                        Choose the firmware on this radio. Isthmus then detects
                        which CDC is config vs mesh traffic (lower ttyACM is
                        config if the handshake is quiet).
                      </p>
                    <% true -> %>
                  <% end %>
                </div>
                <div class="flex flex-wrap items-center gap-2">
                  <button
                    :if={device.ble?}
                    class="btn btn-outline btn-sm"
                    id={"disconnect-ble-#{device_dom_id(device.id)}"}
                    phx-click="disconnect_ble"
                    phx-value-address={device.ble_address}
                    type="button"
                  >
                    Disconnect
                  </button>
                  <button
                    :if={device.companion?}
                    class="btn btn-outline btn-sm"
                    id={"reconnect-#{device_dom_id(device.id)}"}
                    phx-click="reconnect_companion"
                    phx-value-port={companion_port(device)}
                    type="button"
                    disabled={device.ble? and @ble_busy}
                    title={(device.ble? and @ble_busy) && "Wait for Bluetooth to finish"}
                  >
                    Reconnect
                  </button>
                  <button
                    :if={device.companion?}
                    class={["btn btn-outline btn-sm", @channel_syncing && "loading"]}
                    phx-click="sync_meshcore_channels"
                    phx-value-port={companion_port(device)}
                    id={"sync-channels-#{device_dom_id(device.id)}"}
                    type="button"
                    disabled={@channel_syncing or not device.active_companion?}
                  >
                    {if(@channel_syncing, do: "Syncing…", else: "Sync channels")}
                  </button>
                  <%= if kind = radio_config_kind(device) do %>
                    <button
                      class="btn btn-primary btn-sm"
                      id={"open-radio-#{device_dom_id(device.id)}"}
                      phx-click="open_radio_config"
                      phx-value-device-id={device.id}
                      type="button"
                      disabled={not radio_config_active?(device, kind)}
                    >
                      Radio configuration
                    </button>
                  <% end %>
                  <button
                    :if={not device.ble?}
                    class="btn btn-outline btn-sm"
                    id={"open-ports-#{device_dom_id(device.id)}"}
                    phx-click="open_ports_channels"
                    phx-value-device-id={device.id}
                    type="button"
                  >
                    {if(device.active_companion?, do: "Ports & channels", else: "USB ports")}
                  </button>
                </div>
              </div>

              <.usb_firmware_picker
                :if={not device.ble?}
                id={"usb-firmware-#{device_dom_id(device.id)}"}
                device_id={device.id}
                current={UsbRole.firmware_kind(device)}
                source={List.first(device.ports || [])[:source]}
              />
              <.usb_firmware_offer
                :if={not device.ble?}
                id={"usb-firmware-offer-#{device_dom_id(device.id)}"}
                device_id={device.id}
                kind={UsbRole.firmware_kind(device)}
                board_id={IsthmusWeb.Admin.FirmwareOffer.board_id(device, @board_by_device)}
                running_version={device[:firmware_version]}
                connected={device.active_companion? == true or device.active_bridge_cli? == true}
                catalog={@firmware_catalog}
                source={List.first(device.ports || [])[:source]}
              />

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
                  No mesh contacts loaded yet. Create groups on <.link
                    navigate={~p"/admin/registrations"}
                    class="link"
                  >Groups</.link>,
                  assign one on a companion slot, or mint a contact from /me.
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

        <div
          :if={@ports_modal_device}
          class="modal modal-open"
          role="dialog"
          id="meshcore-ports-modal"
        >
          <% device = @ports_modal_device %>
          <div class="modal-box max-w-3xl">
            <h3 class="text-lg font-semibold">
              {if(device.active_companion?, do: "Ports & channels", else: "USB ports")} — {device.label}
            </h3>
            <p class="mt-1 text-sm opacity-70">
              Firmware already classified these USB ports. Change a role only if
              Isthmus got it wrong.
            </p>
            <div class="mt-4 overflow-x-auto">
              <table class="table table-sm" id={"#{device_dom_id(device.id)}-ports"}>
                <thead>
                  <tr>
                    <th>Device</th>
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
                    <td class="font-mono text-sm">
                      {AdminCopy.usb_device_name(port.path) || port.path}
                    </td>
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
                    <td>
                      <.usb_role_picker
                        :if={not device.ble?}
                        id={"usb-role-#{device_dom_id(device.id)}-#{port_dom_key(port.path)}"}
                        path={port.path}
                        serial_number={port[:serial_number] || device.serial_number}
                        vendor_id={port[:vendor_id] || device.vendor_id}
                        product_id={port[:product_id] || device.product_id}
                        current={port.role}
                        source={port[:source]}
                        compact={true}
                      />
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>

            <div :if={device.active_companion?} class="mt-6 space-y-2">
              <h4 class="text-sm font-medium">Channels</h4>
              <div class="overflow-x-auto">
                <table class="table table-sm" id={"channels-#{device_dom_id(device.id)}"}>
                  <thead>
                    <tr>
                      <th>Slot</th>
                      <th>Name</th>
                      <th>Role</th>
                      <th>Linked group</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr
                      :for={ch <- channel_rows(device.channels)}
                      id={"#{device_dom_id(device.id)}-ch-#{ch.index}"}
                    >
                      <td>{ch.index}</td>
                      <td>{if ch.empty?, do: "—", else: ch.name}</td>
                      <td>
                        <span class={[
                          "badge badge-sm",
                          ch.empty? && "badge-ghost",
                          not ch.empty? && ch.index == 0 && "badge-warning",
                          not ch.empty? && ch.index != 0 && "badge-primary"
                        ]}>
                          {slot_role(ch)}
                        </span>
                      </td>
                      <td>
                        <%= if ch.index == 0 do %>
                          <span class="opacity-60">—</span>
                        <% else %>
                          <% radio_id = meshcore_radio_id(device) %>
                          <% linked =
                            RadioChannels.linked_group(@groups, ch.index, radio_id, "meshcore") %>
                          <% choices =
                            RadioChannels.assignable_groups(
                              @bridges,
                              ch.index,
                              radio_id,
                              "meshcore"
                            ) %>
                          <%= if @bridges == [] do %>
                            <p class="text-xs opacity-70">
                              <.link navigate={~p"/admin/registrations"} class="link">
                                Create a group
                              </.link>
                              first.
                            </p>
                          <% else %>
                            <%= if is_nil(radio_id) do %>
                              <p class="text-xs opacity-70">
                                Waiting for this radio’s identity.
                              </p>
                            <% else %>
                              <div class="flex flex-wrap items-center gap-2">
                                <form
                                  id={"slot-group-form-#{device_dom_id(device.id)}-#{ch.index}"}
                                  phx-change="assign_slot_group"
                                  class="min-w-0 grow"
                                >
                                  <input type="hidden" name="radio_id" value={radio_id} />
                                  <input type="hidden" name="port" value={companion_port(device)} />
                                  <input type="hidden" name="channel_idx" value={ch.index} />
                                  <select
                                    id={"slot-group-#{device_dom_id(device.id)}-#{ch.index}"}
                                    name="group_id"
                                    class="select select-bordered select-sm w-full max-w-xs"
                                  >
                                    <option value="" selected={is_nil(linked)}>—</option>
                                    <option
                                      :for={g <- choices}
                                      value={g.id}
                                      selected={linked && linked.id == g.id}
                                    >
                                      {g.display_name}
                                    </option>
                                  </select>
                                </form>
                                <button
                                  :if={linked}
                                  type="button"
                                  class="btn btn-outline btn-xs shrink-0"
                                  id={"show-invite-#{device_dom_id(device.id)}-#{ch.index}"}
                                  phx-click="show_channel_invite"
                                  phx-value-id={linked.id}
                                  phx-value-radio_id={radio_id}
                                >
                                  Invite
                                </button>
                              </div>
                            <% end %>
                          <% end %>
                        <% end %>
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </div>
            <div class="modal-action">
              <button
                class="btn btn-ghost btn-sm"
                type="button"
                id="close-ports-modal-btn"
                phx-click="close_ports_channels"
              >
                Close
              </button>
            </div>
          </div>
          <div class="modal-backdrop" phx-click="close_ports_channels"></div>
        </div>

        <div
          :if={@channel_invite}
          class="modal modal-open"
          role="dialog"
          id="meshcore-invite-modal"
        >
          <div class="modal-box max-w-lg">
            <h3 class="text-lg font-semibold">Channel invite</h3>
            <p class="text-sm opacity-70 mt-1">
              On another MeshCore device: join this private channel, then send a message —
              Isthmus fans it out to attached group members.
            </p>
            <div class="mt-4 grid gap-4 md:grid-cols-2" id="channel-invite-panel">
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
            <div class="modal-action">
              <button
                class="btn btn-ghost btn-sm"
                type="button"
                id="hide-channel-invite-btn"
                phx-click="hide_channel_invite"
              >
                Close
              </button>
            </div>
          </div>
          <div class="modal-backdrop" phx-click="hide_channel_invite"></div>
        </div>

        <div
          :if={@radio_modal}
          class="modal modal-open"
          role="dialog"
          id="meshcore-radio-modal"
        >
          <div class="modal-box max-w-lg">
            <h3 class="text-lg font-semibold">Radio configuration</h3>
            <p class="text-sm opacity-70 mt-1">
              <%= if @radio_modal.kind == :companion do %>
                MeshCore app presets, or frequency and TX for {@radio_modal.label}.
              <% else %>
                MeshCore app presets for {@radio_modal.label}. Apply reboots the radio —
                mesh traffic drops briefly.
              <% end %>
            </p>
            <.form
              for={@radio_form}
              id="meshcore-radio-form"
              phx-change="validate_radio"
              phx-submit={
                if(@radio_modal.kind == :companion,
                  do: "save_companion_radio",
                  else: "apply_repeater_radio"
                )
              }
              class="mt-4 space-y-3"
            >
              <input type="hidden" name="device_id" value={@radio_modal.device_id} />
              <.radio_fields form={@radio_form} id_prefix="meshcore-radio" />
              <div class="modal-action">
                <button
                  class="btn btn-ghost btn-sm"
                  type="button"
                  id="close-meshcore-radio-modal-btn"
                  phx-click="close_radio_config"
                >
                  Cancel
                </button>
                <%= if @radio_modal.kind == :companion do %>
                  <button
                    class="btn btn-primary btn-sm"
                    type="submit"
                    id="save-companion-radio-btn"
                  >
                    Save
                  </button>
                <% else %>
                  <button
                    class={["btn btn-primary btn-sm", @radio_applying && "loading"]}
                    type="submit"
                    id="apply-repeater-radio-btn"
                    disabled={@radio_applying}
                  >
                    {if(@radio_applying, do: "Applying…", else: "Apply & reboot")}
                  </button>
                <% end %>
              </div>
            </.form>
          </div>
          <div class="modal-backdrop" phx-click="close_radio_config"></div>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
