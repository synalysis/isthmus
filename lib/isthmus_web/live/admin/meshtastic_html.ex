defmodule IsthmusWeb.Admin.MeshtasticHTML do
  @moduledoc false
  use IsthmusWeb, :html

  alias Isthmus.Networks.Meshtastic.DeviceConfig
  alias Isthmus.Networks.Meshtastic.RadioConfig
  alias Isthmus.QR
  alias Isthmus.Registrations
  alias IsthmusWeb.Admin.RadioChannels

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
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <section class="space-y-10">
        <.admin_header current={:meshtastic} title="Meshtastic">
          Connect <strong class="font-medium">companion radios</strong>
          over USB serial and link a private channel to an Isthmus group.
        </.admin_header>

        <div class="space-y-4" id="connected-radios">
          <div class="flex flex-wrap items-start justify-between gap-3">
            <div>
              <h2 class="text-lg font-medium">Connected radios</h2>
              <p class="text-xs opacity-70 mt-1">
                Each USB companion is listed separately. Slot 0 is PRIMARY
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
              <.link navigate={~p"/admin/registrations"} class="link link-hover text-sm">
                Manage groups →
              </.link>
            </div>
          </div>

          <%= if @devices == [] do %>
            <div class="rounded-lg border border-base-300 bg-base-200/50 p-4" id="devices-empty">
              <p class="text-sm opacity-70">
                No Meshtastic companions found. Plug in a radio, then Rescan.
                Pin <code class="font-mono">ISTHMUS_MESHTASTIC_PORT</code>
                only to override auto-detect.
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
                    <span class="badge badge-sm badge-outline">{purpose_title}</span>
                    <span class={["badge badge-sm", AdminCopy.status_badge_class(status_atom)]}>
                      {status_text}
                    </span>
                    <span :if={device.primary?} class="badge badge-sm badge-ghost">primary</span>
                  </div>
                  <p class="text-sm opacity-80">{purpose_blurb}</p>
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
                </div>
                <div class="flex flex-wrap items-center gap-2">
                  <button
                    class="btn btn-outline btn-sm"
                    id={"reconnect-#{device_dom_id(device)}"}
                    phx-click="reconnect"
                    phx-value-port={device.path}
                    type="button"
                    disabled={is_nil(device.path)}
                  >
                    Reconnect
                  </button>
                  <button
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
                    class="btn btn-primary btn-sm"
                    id={"open-settings-#{device_dom_id(device)}"}
                    phx-click="open_device_config"
                    phx-value-port={device.path}
                    type="button"
                    disabled={not device.active?}
                  >
                    Device settings
                  </button>
                </div>
              </div>

              <details class="text-xs opacity-70">
                <summary class="cursor-pointer font-medium opacity-90">Technical details</summary>
                <p class="mt-2 font-mono break-all">{device.path}</p>
                <p :if={device.id} class="font-mono break-all">{device.id}</p>
              </details>

              <div :if={device.active?} class="space-y-4">
                <div class="overflow-x-auto">
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
                            <span class="opacity-60">—</span>
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
                                  Waiting for this radio’s node id.
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
              </div>
            </div>
          </div>
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
