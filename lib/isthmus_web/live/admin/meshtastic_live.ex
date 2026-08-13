defmodule IsthmusWeb.Admin.MeshtasticLive do
  use IsthmusWeb, :live_view

  alias Isthmus.Networks.MeshCore.Discover
  alias Isthmus.Networks.Meshtastic.Companion
  alias Isthmus.Networks.Meshtastic.Devices
  alias Isthmus.Networks.Meshtastic.RadioConfig
  alias Isthmus.QR
  alias Isthmus.Registrations

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Isthmus.PubSub, "meshtastic:channels")
      Phoenix.PubSub.subscribe(Isthmus.PubSub, "meshtastic:lora")
      :timer.send_interval(5_000, self(), :refresh)
    end

    {:ok,
     socket
     |> assign(:page_title, "Meshtastic")
     |> assign(:channel_syncing, false)
     |> assign(:lora_applying, false)
     |> assign(:lora_modal_port, nil)
     |> assign(:channel_invite, nil)
     |> assign(:lora_form, to_form(RadioConfig.empty_form_params(), as: :lora))
     |> refresh()}
  end

  @impl true
  def handle_event("sync_channels", %{"port" => port}, socket) do
    health = Companion.health(port)

    if health.status == :online do
      Companion.sync_channels_async(port)

      {:noreply,
       socket
       |> assign(:channel_syncing, true)
       |> put_flash(:info, "Syncing Meshtastic channels…")}
    else
      {:noreply,
       put_flash(
         socket,
         :error,
         "Meshtastic companion offline — plug in a radio or pin ISTHMUS_MESHTASTIC_PORT."
       )}
    end
  end

  def handle_event("reconnect", %{"port" => port}, socket) do
    Companion.reconnect(port)

    {:noreply,
     socket
     |> put_flash(:info, "Reconnecting Meshtastic companion…")
     |> refresh()}
  end

  def handle_event("rescan_devices", _params, socket) do
    case Discover.refresh() do
      {:ok, roles} ->
        n = length(roles[:meshtastic_ports] || [])

        msg =
          cond do
            n > 1 ->
              "Rescanned — #{n} Meshtastic companions."

            n == 1 ->
              "Rescanned — Meshtastic companion on #{hd(roles[:meshtastic_ports]).path}."

            match?(%{path: _}, roles[:meshtastic]) ->
              "Rescanned — Meshtastic companion on #{roles[:meshtastic].path}."

            true ->
              "Rescanned — no Meshtastic companion found."
          end

        {:noreply, socket |> put_flash(:info, msg) |> refresh()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Rescan failed: #{inspect(reason)}")}
    end
  end

  def handle_event("open_radio_config", %{"port" => port}, socket) do
    lora = Companion.lora_config(port)

    {:noreply,
     socket
     |> assign(:lora_modal_port, port)
     |> assign(:lora_form, to_form(RadioConfig.to_form_params(lora), as: :lora))}
  end

  def handle_event("close_radio_config", _params, socket) do
    {:noreply, assign(socket, :lora_modal_port, nil)}
  end

  def handle_event("assign_slot_group", params, socket) do
    idx = parse_slot(params["channel_idx"])
    port = blank_port(params["port"])
    group_id = String.trim(to_string(params["group_id"] || ""))
    current = linked_group(socket.assigns.groups, idx)

    cond do
      idx not in 1..7 ->
        {:noreply,
         put_flash(socket, :error, "Pick a secondary slot (1–7). Slot 0 is PRIMARY / frequency.")}

      group_id == "" and is_nil(current) ->
        {:noreply, socket}

      group_id == "" ->
        unlink_slot(socket, current, port)

      current && current.id == group_id ->
        {:noreply, socket}

      empty_channel?(Companion.list_channels(port), idx) ->
        provision_channel(socket, Registrations.get_group!(group_id), idx: idx, port: port)

      true ->
        link_occupied_slot(socket, group_id, idx, port, current)
    end
  end

  def handle_event("validate_lora", %{"lora" => params}, socket) do
    {:noreply, assign(socket, :lora_form, to_form(params, as: :lora))}
  end

  def handle_event("save_lora", %{"lora" => params} = all, socket) do
    port = blank_port(all["port"] || socket.assigns.lora_modal_port)
    socket = assign(socket, :lora_applying, true)

    case Companion.set_lora_config(params, port) do
      {:ok, lora} ->
        {:noreply,
         socket
         |> assign(:lora_applying, false)
         |> assign(:lora_modal_port, nil)
         |> assign(:lora_form, to_form(RadioConfig.to_form_params(lora), as: :lora))
         |> put_flash(
           :info,
           "LoRa config written — radio is rebooting and will reconnect shortly."
         )
         |> refresh()}

      {:error, :not_connected} ->
        {:noreply,
         socket
         |> assign(:lora_applying, false)
         |> put_flash(:error, "Meshtastic companion offline.")}

      {:error, :timeout} ->
        {:noreply,
         socket
         |> assign(:lora_applying, false)
         |> put_flash(:error, "Timed out talking to Meshtastic companion.")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:lora_applying, false)
         |> put_flash(:error, "LoRa config failed: #{format_err(reason)}")}
    end
  end

  def handle_event("show_channel_invite", %{"id" => id}, socket) do
    group = Registrations.get_group!(id)

    case Registrations.meshtastic_channel_invite(group) do
      {:ok, invite} ->
        {:noreply, assign(socket, :channel_invite, invite)}

      {:error, :no_channel_linked} ->
        {:noreply, put_flash(socket, :error, "No Meshtastic channel linked to this group.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not decrypt channel invite.")}
    end
  end

  def handle_event("hide_channel_invite", _params, socket) do
    {:noreply, assign(socket, :channel_invite, nil)}
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, refresh(socket)}

  def handle_info({:meshtastic_channels, channels, _port}, socket) when is_list(channels) do
    {:noreply, socket |> assign(:channel_syncing, false) |> refresh()}
  end

  def handle_info({:meshtastic_lora, lora, port}, socket) when is_map(lora) do
    socket =
      if socket.assigns.lora_modal_port == port do
        assign(socket, :lora_form, to_form(RadioConfig.to_form_params(lora), as: :lora))
      else
        socket
      end

    {:noreply, refresh(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp refresh(socket) do
    groups = Registrations.list_all()
    bridges = Enum.filter(groups, &(&1.kind == "bridge" and &1.status == "active"))

    socket
    |> assign(:groups, groups)
    |> assign(:bridges, bridges)
    |> assign(:devices, Devices.inventory())
    |> assign(:lora_applying, socket.assigns[:lora_applying] || false)
  end

  defp provision_channel(socket, group, opts) do
    result =
      try do
        Registrations.provision_meshtastic_channel(group, opts)
      catch
        :exit, {:timeout, _} -> {:error, :timeout}
        :exit, reason -> {:error, {:exit, reason}}
      end

    case result do
      {:ok, linked} ->
        {:noreply,
         socket
         |> assign(:channel_invite, nil)
         |> put_flash(
           :info,
           "Private Meshtastic channel created on slot #{linked.meshtastic_channel_idx}."
         )
         |> refresh()}

      {:error, :not_connected} ->
        {:noreply, put_flash(socket, :error, "Meshtastic companion offline.")}

      {:error, :no_empty_channel_slot} ->
        {:noreply, put_flash(socket, :error, "No empty secondary channel slots (1–7).")}

      {:error, :slot_occupied} ->
        {:noreply, put_flash(socket, :error, "That slot is already configured on the radio.")}

      {:error, :already_linked} ->
        {:noreply, put_flash(socket, :error, "This group already has a Meshtastic channel.")}

      {:error, :timeout} ->
        {:noreply, put_flash(socket, :error, "Timed out talking to Meshtastic companion.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not create channel: #{inspect(reason)}")}
    end
  end

  defp unlink_slot(socket, group, port) do
    idx = group.meshtastic_channel_idx

    case clear_radio_slot(idx, port) do
      :ok ->
        finish_unlink(socket, group, "Channel unlinked and slot #{idx} cleared on the radio.")

      {:error, :not_connected} ->
        finish_unlink(
          socket,
          group,
          "Channel unlinked. Companion offline — the radio slot was not cleared."
        )

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Could not clear radio slot #{idx}: #{format_err(reason)}")}
    end
  end

  defp clear_radio_slot(idx, port) when is_integer(idx) and idx in 1..7 do
    case Companion.clear_channel(idx, port) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  defp clear_radio_slot(_, _), do: :ok

  defp finish_unlink(socket, group, message) do
    case Registrations.unlink_meshtastic_channel(group) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:channel_invite, nil)
         |> put_flash(:info, message)
         |> refresh()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Unlink failed: #{inspect(reason)}")}
    end
  end

  defp link_occupied_slot(socket, group_id, idx, port, current) do
    group = Registrations.get_group!(group_id)

    with :ok <- maybe_unlink(current),
         %{psk_hex: psk} when is_binary(psk) and psk != "" <- Companion.get_channel(idx, port),
         {:ok, _} <- Registrations.link_meshtastic_channel(group, idx, psk) do
      {:noreply,
       socket
       |> assign(:channel_invite, nil)
       |> put_flash(:info, "Channel #{idx} linked to #{group.display_name}.")
       |> refresh()}
    else
      {:error, :unlink_failed, reason} ->
        {:noreply, put_flash(socket, :error, "Unlink failed: #{inspect(reason)}")}

      nil ->
        {:noreply, put_flash(socket, :error, "Channel not in companion cache — sync first.")}

      %{psk_hex: _} ->
        {:noreply,
         put_flash(socket, :error, "Channel has no PSK — pick a private secondary slot.")}

      {:error, :channel_already_linked} ->
        {:noreply, put_flash(socket, :error, "Channel already linked to another group.")}

      {:error, :not_a_bridge_group} ->
        {:noreply, put_flash(socket, :error, "Only bridge groups can link channels.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Link failed: #{inspect(reason)}")}
    end
  end

  defp maybe_unlink(nil), do: :ok

  defp maybe_unlink(group) do
    case Registrations.unlink_meshtastic_channel(group) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, :unlink_failed, reason}
    end
  end

  defp parse_slot(idx) when is_integer(idx), do: idx

  defp parse_slot(idx) when is_binary(idx) do
    case Integer.parse(idx) do
      {n, ""} -> n
      _ -> -1
    end
  end

  defp parse_slot(_), do: -1

  defp blank_port(port) when is_binary(port) and port != "", do: port
  defp blank_port(_), do: nil

  defp port_dom_key(path) do
    path
    |> to_string()
    |> String.replace(~r/[^A-Za-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp device_dom_id(device), do: "meshtastic-device-#{port_dom_key(device.path || device.id)}"

  defp empty_channel?(channels, idx) do
    case Enum.find(channels, &(&1.index == idx)) do
      %{empty?: true} -> true
      nil -> true
      _ -> false
    end
  end

  defp format_err(reason) when is_binary(reason), do: reason
  defp format_err(reason), do: inspect(reason)

  defp lora_mode(form) do
    case form[:mode].value do
      "custom" -> "custom"
      _ -> "preset"
    end
  end

  defp linked_group(groups, idx) do
    Enum.find(groups, &(&1.status == "active" and &1.meshtastic_channel_idx == idx))
  end

  defp assignable_groups(bridges, idx) do
    Enum.filter(bridges, fn g ->
      is_nil(g.meshtastic_channel_idx) or g.meshtastic_channel_idx == idx
    end)
  end

  defp role_label(1), do: "primary"
  defp role_label(2), do: "secondary"
  defp role_label(_), do: "empty"

  @impl true
  def render(assigns) do
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
                (frequency); assign a group to slots 1–7. <strong class="font-medium">Invite</strong>
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
                    )} · hops {health[:hop_limit] || 3}
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
                    id={"open-lora-#{device_dom_id(device)}"}
                    phx-click="open_radio_config"
                    phx-value-port={device.path}
                    type="button"
                    disabled={not device.active?}
                  >
                    Radio configuration
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
                            <% linked = linked_group(@groups, ch.index) %>
                            <% choices = assignable_groups(@bridges, ch.index) %>
                            <%= if @bridges == [] do %>
                              <p class="text-xs opacity-70">
                                <.link navigate={~p"/admin/registrations"} class="link">
                                  Create a group
                                </.link>
                                first.
                              </p>
                            <% else %>
                              <div class="flex flex-wrap items-center gap-2">
                                <form
                                  id={"slot-group-form-#{device_dom_id(device)}-#{ch.index}"}
                                  phx-change="assign_slot_group"
                                  class="min-w-0 grow"
                                >
                                  <input type="hidden" name="port" value={device.path} />
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
                                >
                                  Invite
                                </button>
                              </div>
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
          :if={@lora_modal_port}
          class="modal modal-open"
          role="dialog"
          id="meshtastic-lora-modal"
        >
          <div class="modal-box max-w-lg">
            <h3 class="text-lg font-semibold">Radio configuration</h3>
            <p class="text-sm opacity-70 mt-1">
              Region and modem preset, or explicit bandwidth / spreading factor /
              coding rate. Apply writes LoRa config and reboots this companion.
            </p>
            <.form
              for={@lora_form}
              id="meshtastic-lora-form"
              phx-change="validate_lora"
              phx-submit="save_lora"
              class="mt-4 space-y-3"
            >
              <input type="hidden" name="port" value={@lora_modal_port} />
              <div class="grid gap-3 sm:grid-cols-2">
                <.input
                  field={@lora_form[:region]}
                  type="select"
                  label="Region"
                  options={RadioConfig.region_options()}
                  id="lora-region"
                />
                <.input
                  field={@lora_form[:mode]}
                  type="select"
                  label="Modem"
                  options={RadioConfig.mode_options()}
                  id="lora-mode"
                />
              </div>
              <%= if lora_mode(@lora_form) == "custom" do %>
                <div class="grid grid-cols-2 gap-3 sm:grid-cols-4">
                  <.input
                    field={@lora_form[:bandwidth]}
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
                    field={@lora_form[:spread_factor]}
                    type="number"
                    label="SF"
                    min="7"
                    max="12"
                    id="lora-sf"
                  />
                  <.input
                    field={@lora_form[:coding_rate]}
                    type="number"
                    label="CR"
                    min="5"
                    max="8"
                    id="lora-cr"
                  />
                  <.input
                    field={@lora_form[:override_frequency]}
                    type="text"
                    label="Freq (MHz, optional)"
                    placeholder="leave blank for region default"
                    id="lora-freq"
                  />
                </div>
              <% else %>
                <.input
                  field={@lora_form[:modem_preset]}
                  type="select"
                  label="Preset"
                  options={RadioConfig.preset_options()}
                  id="lora-preset"
                />
              <% end %>
              <div class="grid grid-cols-2 gap-3 sm:grid-cols-3">
                <.input
                  field={@lora_form[:hop_limit]}
                  type="number"
                  label="Hop limit"
                  min="1"
                  max="7"
                  id="lora-hops"
                />
                <.input
                  field={@lora_form[:tx_power]}
                  type="number"
                  label="TX (dBm, 0 = max legal)"
                  min="0"
                  max="30"
                  id="lora-tx"
                />
                <.input
                  field={@lora_form[:channel_num]}
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
              <div class="modal-action">
                <button
                  class="btn btn-ghost btn-sm"
                  type="button"
                  id="close-lora-modal-btn"
                  phx-click="close_radio_config"
                >
                  Cancel
                </button>
                <button
                  class={["btn btn-primary btn-sm", @lora_applying && "loading"]}
                  type="submit"
                  id="save-lora-btn"
                  disabled={@lora_applying}
                >
                  {if(@lora_applying, do: "Applying…", else: "Apply & reboot")}
                </button>
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
