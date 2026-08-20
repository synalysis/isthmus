defmodule IsthmusWeb.Admin.MeshtasticHTML do
  @moduledoc false
  use IsthmusWeb, :html

  alias Isthmus.Networks.Meshtastic.DeviceConfig
  alias Isthmus.Networks.Meshtastic.RadioConfig
  alias Isthmus.QR
  alias Isthmus.Registrations
  alias IsthmusWeb.Admin.RadioChannels
  alias IsthmusWeb.Admin.UsbRole
  import IsthmusWeb.Admin.UsbRole, only: [usb_firmware_picker: 1]
  import IsthmusWeb.Admin.FirmwareOffer, only: [usb_firmware_offer: 1]

  defp port_dom_key(path) do
    path
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp device_dom_id(device), do: "meshtastic-device-#{port_dom_key(device.path || device.id)}"

  defp radio_clock_at(health) when is_map(health) do
    case health[:device_time_now] || health[:device_time] do
      unix when is_integer(unix) and unix > 0 ->
        case DateTime.from_unix(unix) do
          {:ok, dt} -> dt
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp radio_clock_at(_), do: nil

  defp lora_mode(form) do
    case form[:mode].value do
      "custom" -> "custom"
      _ -> "preset"
    end
  end

  def meshtastic_radio_id(device) when is_map(device) do
    Registrations.normalize_radio_id(get_in(device, [:health, :node_id]) || device[:node_id])
  end

  defp role_label(1), do: "primary"

  defp role_label(2), do: "secondary"

  defp role_label(_), do: "empty"

  def page(assigns) do
    assigns =
      assign(
        assigns,
        :channels_modal_device,
        Enum.find(assigns[:devices] || [], &(&1.id == assigns[:channels_modal_id]))
      )

    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <section class="space-y-10">
        <.admin_header current={:meshtastic} title="Meshtastic">
          Connect <strong class="font-medium">companion radios</strong>
          over USB serial or Bluetooth and link a private channel to an Isthmus group.
        </.admin_header>

        <div class="space-y-4" id="connected-radios">
          <div class="flex flex-wrap items-start justify-between gap-3">
            <div>
              <h2 class="text-lg font-medium">Connected radios</h2>
              <p class="text-xs opacity-70 mt-1">
                Each USB companion is listed separately. Choose firmware on the
                radio — Isthmus does not guess Meshtastic vs MeshCore.
                Slot 0 is PRIMARY
                (frequency); assign a group to slots 1–7 on <strong class="font-medium">this</strong>
                radio’s node id — the same slot on another radio is a different channel.
                <strong class="font-medium">Invite</strong>
                shows the PSK / QR for another Meshtastic device.
              </p>
            </div>
            <div class="flex flex-wrap items-center gap-3">
              <button
                class="btn btn-outline btn-sm"
                id="rescan-meshtastic-btn"
                phx-click="rescan_devices"
                type="button"
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
            <h3 class="text-sm font-medium">Nearby Meshtastic Bluetooth</h3>
            <p class="text-xs opacity-70 mt-1">
              Connect uses the existing Bluetooth bond when this host already
              paired the radio. A PIN appears only on first pairing.
              Connected radios come back after a server restart until you Disconnect.
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
                    <td class="text-sm">{dev.name || "Meshtastic"}</td>
                    <td class="font-mono text-xs">{dev.address}</td>
                    <td class="text-xs opacity-70">{dev.rssi || "—"}</td>
                    <td>
                      <form
                        id={"ble-connect-#{port_dom_key(dev.address)}"}
                        phx-submit="connect_ble"
                        class="flex flex-wrap items-center justify-end gap-2"
                      >
                        <input type="hidden" name="address" value={dev.address} />
                        <input type="hidden" name="name" value={dev.name || ""} />
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
                No Meshtastic companions found. Plug in a USB radio, choose
                <strong class="font-medium">Meshtastic companion</strong>
                on that port, or use <strong class="font-medium">Scan Bluetooth</strong>
                for a pairing-mode companion.
                Pin <code class="font-mono">ISTHMUS_MESHTASTIC_PORT</code>
                to skip the USB role picker.
              </p>
            </div>
          <% end %>

          <div
            :for={device <- @devices}
            class="card bg-base-200 border border-base-300"
            id={device_dom_id(device)}
            data-port={device.path}
          >
            <% {purpose_title, purpose_blurb} = AdminCopy.device_purpose(device) %>
            <% {status_atom, status_text} = AdminCopy.device_status(device) %>
            <% health = device.health %>
            <div class="card-body space-y-5">
              <div class="flex flex-wrap items-start justify-between gap-3">
                <div class="min-w-0 space-y-1">
                  <div class="flex flex-wrap items-center gap-2">
                    <h3 class="card-title text-lg">{device.label}</h3>
                    <span
                      :if={name = AdminCopy.usb_device_name(device.path)}
                      class="font-mono text-sm opacity-70"
                    >
                      {name}
                    </span>
                    <span class="badge badge-sm badge-outline">{purpose_title}</span>
                    <span :if={device.ble?} class="badge badge-sm badge-info">Bluetooth</span>
                    <span class={["badge badge-sm", AdminCopy.status_badge_class(status_atom)]}>
                      {status_text}
                    </span>
                    <span :if={device.primary?} class="badge badge-sm badge-ghost">primary</span>
                    <span
                      :if={
                        IsthmusWeb.Admin.FirmwareOffer.newer?(
                          device,
                          @board_by_device,
                          @firmware_catalog
                        )
                      }
                      class="badge badge-sm badge-warning"
                      id={"#{device_dom_id(device)}-firmware-update"}
                    >
                      Firmware update
                    </span>
                  </div>
                  <p class="text-sm opacity-80">{purpose_blurb}</p>
                  <%= cond do %>
                    <% AdminCopy.usb_permission_denied?(device) -> %>
                      <p
                        class="text-sm text-warning"
                        id={"#{device_dom_id(device)}-identify-hint"}
                      >
                        Isthmus cannot open this USB port (permission denied). Pass
                        <code class="text-xs">/dev/ttyUSB*</code>
                        into the container and do not set a non-root user — the
                        entrypoint chmods the node, then drops to nobody.
                      </p>
                    <% device.kind == :unknown -> %>
                      <p
                        class="text-sm text-warning"
                        id={"#{device_dom_id(device)}-identify-hint"}
                      >
                        Choose the firmware on this radio. Dual CDC ports are
                        classified after that — you do not pick config vs traffic
                        by hand.
                      </p>
                    <% true -> %>
                  <% end %>
                  <p
                    :if={device.active? and health[:region_label]}
                    class="text-sm opacity-70"
                  >
                    {RadioConfig.region_label(health[:region])} · {if(
                      health[:use_preset],
                      do: RadioConfig.preset_label(health[:modem_preset]),
                      else: "custom LoRa"
                    )} · hops {health[:hop_limit] || 3} · {DeviceConfig.buzzer_label(
                      health[:buzzer_mode]
                    )}
                  </p>
                  <p
                    :if={device.active?}
                    class="text-sm opacity-70"
                    id={"radio-clock-#{device_dom_id(device)}"}
                  >
                    <%= if clock = radio_clock_at(health) do %>
                      Radio clock (local)
                      <.local_time
                        id={"mt-clock-#{device_dom_id(device)}"}
                        at={clock}
                        class="whitespace-nowrap text-sm font-mono"
                      />
                      <span :if={health[:time_synced_at]} class="opacity-60"> · synced</span>
                    <% else %>
                      Radio clock unset
                    <% end %>
                  </p>
                  <p :if={health[:last_error] && not device.active?} class="text-sm text-warning">
                    {health.last_error}
                  </p>
                  <p
                    :if={device.active? and is_nil(meshtastic_radio_id(device))}
                    class="text-sm text-warning"
                    id={"#{device_dom_id(device)}-node-id-hint"}
                  >
                    Serial is open, but this radio has not sent its Meshtastic node id
                    yet. USB-UART boards reboot on port open — wait until the
                    radio finishes booting (often ~8s), then
                    <strong class="font-medium">Sync channels</strong>
                    if the node id still does not appear.
                  </p>
                </div>
                <div class="flex flex-wrap items-center gap-2">
                  <button
                    :if={device.ble?}
                    class="btn btn-outline btn-sm"
                    id={"disconnect-ble-#{device_dom_id(device)}"}
                    phx-click="disconnect_ble"
                    phx-value-address={device.ble_address}
                    type="button"
                  >
                    Disconnect
                  </button>
                  <button
                    :if={device.kind == :meshtastic}
                    class="btn btn-outline btn-sm"
                    id={"reconnect-#{device_dom_id(device)}"}
                    phx-click="reconnect"
                    phx-value-port={device.path}
                    type="button"
                    disabled={is_nil(device.path) or (device.ble? and @ble_busy)}
                    title={(device.ble? and @ble_busy) && "Wait for Bluetooth to finish"}
                  >
                    Reconnect
                  </button>
                  <button
                    :if={device.kind == :meshtastic}
                    class={[
                      "btn btn-outline btn-sm",
                      @time_syncing_port == device.path && "loading"
                    ]}
                    id={"sync-time-#{device_dom_id(device)}"}
                    phx-click="sync_time"
                    phx-value-port={device.path}
                    type="button"
                    disabled={not device.active? or @time_syncing_port == device.path}
                  >
                    {if(@time_syncing_port == device.path, do: "Syncing time…", else: "Sync time")}
                  </button>
                  <button
                    :if={device.kind == :meshtastic}
                    class={["btn btn-outline btn-sm", @channel_syncing && "loading"]}
                    id={"sync-channels-#{device_dom_id(device)}"}
                    phx-click="sync_channels"
                    phx-value-port={device.path}
                    type="button"
                    disabled={@channel_syncing or not device.active?}
                  >
                    {if(@channel_syncing, do: "Syncing…", else: "Sync channels")}
                  </button>
                  <button
                    :if={device.kind == :meshtastic}
                    class="btn btn-primary btn-sm"
                    id={"open-settings-#{device_dom_id(device)}"}
                    phx-click="open_device_config"
                    phx-value-port={device.path}
                    type="button"
                    disabled={not device.active?}
                  >
                    Device settings
                  </button>
                  <button
                    :if={device.active?}
                    class="btn btn-outline btn-sm"
                    id={"open-channels-#{device_dom_id(device)}"}
                    phx-click="open_channels"
                    phx-value-device-id={device.id}
                    type="button"
                  >
                    Channels
                  </button>
                </div>
              </div>

              <div :if={not device.ble?} class="flex flex-col gap-2">
                <.usb_firmware_picker
                  id={"usb-firmware-#{device_dom_id(device)}"}
                  device_id={device.id}
                  current={UsbRole.firmware_kind(device)}
                  source={device.source}
                />

                <.usb_firmware_offer
                  id={"usb-firmware-offer-#{device_dom_id(device)}"}
                  device_id={device.id}
                  kind={UsbRole.firmware_kind(device)}
                  board_id={IsthmusWeb.Admin.FirmwareOffer.board_id(device, @board_by_device)}
                  running_version={device[:firmware_version]}
                  connected={device.active? == true}
                  catalog={@firmware_catalog}
                  source={device.source}
                />
              </div>

              <details class="text-xs opacity-70">
                <summary class="cursor-pointer font-medium opacity-90">Technical details</summary>
                <p class="mt-2 font-mono break-all">{device.path}</p>
                <p :if={device.id} class="font-mono break-all">{device.id}</p>
              </details>
            </div>
          </div>
        </div>

        <div
          :if={@channels_modal_device}
          class="modal modal-open"
          role="dialog"
          id="meshtastic-channels-modal"
        >
          <% device = @channels_modal_device %>
          <div class="modal-box max-w-3xl">
            <h3 class="text-lg font-semibold">Channels — {device.label}</h3>
            <p class="mt-1 text-sm opacity-70">
              Slot 0 is PRIMARY. Assign a group to slots 1–7 on this radio’s node id.
            </p>
            <div class="mt-4 overflow-x-auto">
              <table class="table table-sm" id={"channels-#{device_dom_id(device)}"}>
                <thead>
                  <tr>
                    <th>Slot</th>
                    <th>Name</th>
                    <th>Role</th>
                    <th>Linked group</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={ch <- device.channels} id={"#{device_dom_id(device)}-ch-#{ch.index}"}>
                    <td>{ch.index}</td>
                    <td>{if ch.empty?, do: "—", else: ch.name}</td>
                    <td>
                      <span class={[
                        "badge badge-sm",
                        ch.empty? && "badge-ghost",
                        not ch.empty? && ch.role == 1 && "badge-warning",
                        not ch.empty? && ch.role != 1 && "badge-primary"
                      ]}>
                        {role_label(ch.role)}
                      </span>
                    </td>
                    <td>
                      <%= if ch.index == 0 do %>
                        <div class="flex w-full flex-wrap items-center justify-end gap-2">
                          <button
                            type="button"
                            class="btn btn-outline btn-xs shrink-0"
                            id={"send-channel-#{device_dom_id(device)}-#{ch.index}"}
                            phx-click="open_send_channel"
                            phx-value-port={device.path}
                            phx-value-channel_idx={ch.index}
                          >
                            Send message
                          </button>
                        </div>
                      <% else %>
                        <% radio_id = meshtastic_radio_id(device) %>
                        <% linked =
                          RadioChannels.linked_group(@groups, ch.index, radio_id, "meshtastic") %>
                        <% choices =
                          RadioChannels.assignable_groups(
                            @bridges,
                            ch.index,
                            radio_id,
                            "meshtastic"
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
                              Waiting for this radio’s node id. If this stays empty,
                              the serial port opened but PhoneAPI never answered —
                              close this dialog and use Sync channels.
                            </p>
                          <% else %>
                            <div class="flex flex-wrap items-center gap-2">
                              <form
                                id={"slot-group-form-#{device_dom_id(device)}-#{ch.index}"}
                                phx-change="assign_slot_group"
                                class="min-w-0 grow"
                              >
                                <input type="hidden" name="port" value={device.path} />
                                <input type="hidden" name="radio_id" value={radio_id} />
                                <input type="hidden" name="channel_idx" value={ch.index} />
                                <select
                                  id={"slot-group-#{device_dom_id(device)}-#{ch.index}"}
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
                                id={"show-invite-#{device_dom_id(device)}-#{ch.index}"}
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
            <div class="modal-action">
              <button
                class="btn btn-ghost btn-sm"
                type="button"
                id="close-channels-modal-btn"
                phx-click="close_channels"
              >
                Close
              </button>
            </div>
          </div>
          <div class="modal-backdrop" phx-click="close_channels"></div>
        </div>

        <div
          :if={@ble_pin_prompt}
          class="modal modal-open"
          role="dialog"
          id="ble-pin-modal"
        >
          <div class="modal-box max-w-md">
            <h3 class="text-lg font-semibold">Enter Bluetooth PIN</h3>
            <p class="mt-1 text-sm opacity-70">
              <%= cond do %>
                <% is_binary(@ble_pin_prompt[:name]) and @ble_pin_prompt[:name] != "" -> %>
                  <span class="font-medium text-base-content">{@ble_pin_prompt[:name]}</span>
                  is pairing. Enter the PIN on its display, or 123456 if it does not show
                  one (already paired, or default PIN).
                <% true -> %>
                  Enter the PIN on the radio display, or 123456 if it does not show one
                  (already paired, or default PIN).
              <% end %>
            </p>
            <.form
              for={@ble_pin_form}
              id="ble-pin-form"
              phx-submit="submit_ble_pin"
              class="mt-4 space-y-4"
            >
              <input type="hidden" name="address" value={@ble_pin_prompt[:address]} />
              <.input
                field={@ble_pin_form[:pin]}
                id="ble-pin-input"
                type="text"
                label="PIN"
                autocomplete="one-time-code"
                maxlength="8"
                class="input input-bordered font-mono tracking-widest"
              />
              <div class="modal-action">
                <button
                  class="btn btn-ghost btn-sm"
                  type="button"
                  id="cancel-ble-pin-btn"
                  phx-click="cancel_ble_pin"
                >
                  Cancel
                </button>
                <button class="btn btn-primary btn-sm" type="submit" id="submit-ble-pin-btn">
                  Pair
                </button>
              </div>
            </.form>
          </div>
          <div class="modal-backdrop" phx-click="cancel_ble_pin"></div>
        </div>

        <div
          :if={@channel_invite}
          class="modal modal-open"
          role="dialog"
          id="meshtastic-invite-modal"
        >
          <div class="modal-box max-w-lg">
            <h3 class="text-lg font-semibold">Channel invite</h3>
            <p class="text-sm opacity-70 mt-1">
              On another Meshtastic device: add this channel, then send a message —
              Isthmus fans it out to attached group members.
            </p>
            <div class="mt-4 grid gap-4 md:grid-cols-2" id="channel-invite-panel">
              <div class="space-y-2" id="channel-invite-secret">
                <h4 class="text-sm font-medium">Channel PSK</h4>
                <dl class="space-y-2 text-sm">
                  <div>
                    <dt class="text-xs opacity-60">Name</dt>
                    <dd class="font-mono select-all">{@channel_invite.name}</dd>
                  </div>
                  <div>
                    <dt class="text-xs opacity-60">PSK</dt>
                    <dd class="font-mono text-xs break-all select-all">
                      {@channel_invite.psk_hex}
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
          :if={@send_channel}
          class="modal modal-open"
          role="dialog"
          id="meshtastic-send-channel-modal"
        >
          <div class="modal-box">
            <h3 class="text-lg font-semibold">
              Send to {@send_channel.name}
            </h3>
            <p class="mt-1 text-sm opacity-70">
              Transmits on this radio's Primary channel (slot {@send_channel.channel_idx}).
              It is not sent through an Isthmus group.
            </p>
            <.form
              for={@send_form}
              id="meshtastic-send-channel-form"
              phx-submit="send_channel_text"
              class="mt-4 space-y-4"
            >
              <input type="hidden" name="port" value={@send_channel.port} />
              <input type="hidden" name="channel_idx" value={@send_channel.channel_idx} />
              <.input
                field={@send_form[:body]}
                type="textarea"
                label="Message"
                placeholder="Hello from Isthmus…"
                rows="5"
              />
              <div class="modal-action">
                <button
                  class="btn btn-ghost btn-sm"
                  type="button"
                  id="close-send-channel-btn"
                  phx-click="close_send_channel"
                >
                  Cancel
                </button>
                <button class="btn btn-primary btn-sm" type="submit" id="send-channel-submit">
                  Send
                </button>
              </div>
            </.form>
          </div>
          <div class="modal-backdrop" phx-click="close_send_channel"></div>
        </div>

        <div
          :if={@settings_modal_port}
          class="modal modal-open"
          role="dialog"
          id="meshtastic-settings-modal"
        >
          <div class="modal-box max-w-xl">
            <h3 class="text-lg font-semibold">Device settings</h3>
            <p class="text-sm opacity-70 mt-1">
              Radio and device options for this companion. Apply writes config and
              reboots the radio. More sections can be added here later.
            </p>
            <.form
              for={@settings_form}
              id="meshtastic-settings-form"
              phx-change="validate_settings"
              phx-submit="save_settings"
              class="mt-4 space-y-6"
            >
              <input type="hidden" name="port" value={@settings_modal_port} />
              <.inputs_for :let={device} field={@settings_form[:device]}>
                <section id="settings-device" class="space-y-3">
                  <h4 class="text-sm font-semibold tracking-wide uppercase opacity-70">
                    Alerts
                  </h4>
                  <.input
                    field={device[:buzzer_mode]}
                    type="select"
                    label="Buzzer"
                    options={DeviceConfig.buzzer_options()}
                    id="device-buzzer-mode"
                  />
                  <p class="text-xs opacity-70 -mt-1">
                    Onboard speaker. Disabled silences incoming-message beeps.
                  </p>
                </section>
              </.inputs_for>
              <.inputs_for :let={lora} field={@settings_form[:lora]}>
                <section id="settings-lora" class="space-y-3">
                  <h4 class="text-sm font-semibold tracking-wide uppercase opacity-70">
                    Radio
                  </h4>
                  <div class="grid gap-3 sm:grid-cols-2">
                    <.input
                      field={lora[:region]}
                      type="select"
                      label="Region"
                      options={RadioConfig.region_options()}
                      id="lora-region"
                    />
                    <.input
                      field={lora[:mode]}
                      type="select"
                      label="Modem"
                      options={RadioConfig.mode_options()}
                      id="lora-mode"
                    />
                  </div>
                  <%= if lora_mode(lora) == "custom" do %>
                    <div class="grid grid-cols-2 gap-3 sm:grid-cols-4">
                      <.input
                        field={lora[:bandwidth]}
                        type="select"
                        label="BW (kHz)"
                        options={[
                          {"31.25", "31"},
                          {"62.5", "62"},
                          {"125", "125"},
                          {"250", "250"},
                          {"500", "500"}
                        ]}
                        id="lora-bandwidth"
                      />
                      <.input
                        field={lora[:spread_factor]}
                        type="number"
                        label="SF"
                        min="7"
                        max="12"
                        id="lora-sf"
                      />
                      <.input
                        field={lora[:coding_rate]}
                        type="number"
                        label="CR"
                        min="5"
                        max="8"
                        id="lora-cr"
                      />
                      <.input
                        field={lora[:override_frequency]}
                        type="text"
                        label="Freq (MHz, optional)"
                        placeholder="leave blank for region default"
                        id="lora-freq"
                      />
                    </div>
                  <% else %>
                    <.input
                      field={lora[:modem_preset]}
                      type="select"
                      label="Preset"
                      options={RadioConfig.preset_options()}
                      id="lora-preset"
                    />
                  <% end %>
                  <div class="grid grid-cols-2 gap-3 sm:grid-cols-3">
                    <.input
                      field={lora[:hop_limit]}
                      type="number"
                      label="Hop limit"
                      min="1"
                      max="7"
                      id="lora-hops"
                    />
                    <.input
                      field={lora[:tx_power]}
                      type="number"
                      label="TX (dBm, 0 = max legal)"
                      min="0"
                      max="30"
                      id="lora-tx"
                    />
                    <.input
                      field={lora[:channel_num]}
                      type="number"
                      label="LoRa channel #"
                      min="0"
                      max="83"
                      id="lora-channel-num"
                    />
                  </div>
                  <p class="text-xs opacity-70">
                    LoRa channel # is the frequency slot inside the region, not a group chat slot.
                  </p>
                </section>
              </.inputs_for>
              <div class="modal-action">
                <button
                  class="btn btn-ghost btn-sm"
                  type="button"
                  id="close-settings-modal-btn"
                  phx-click="close_device_config"
                >
                  Cancel
                </button>
                <button
                  class={["btn btn-primary btn-sm", @settings_applying && "loading"]}
                  type="submit"
                  id="save-settings-btn"
                  disabled={@settings_applying}
                >
                  {if(@settings_applying, do: "Applying…", else: "Apply & reboot")}
                </button>
              </div>
            </.form>
          </div>
          <div class="modal-backdrop" phx-click="close_device_config"></div>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
