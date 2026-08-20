defmodule IsthmusWeb.Admin.MeshtasticLive do
  use IsthmusWeb, :live_view

  alias IsthmusWeb.Admin.MeshtasticHTML

  alias Isthmus.Messages
  alias Isthmus.Networks.BLERemembered
  alias Isthmus.Networks.MeshCore.BLESidecar
  alias Isthmus.Networks.MeshCore.Discover
  alias Isthmus.Networks.Meshtastic.Companion
  alias Isthmus.Networks.Meshtastic.Devices
  alias Isthmus.Networks.Meshtastic.Settings
  alias Isthmus.Networks.Meshtastic.Supervisor, as: MeshtasticSupervisor
  alias Isthmus.Registrations
  alias IsthmusWeb.Admin.FirmwareOffer
  alias IsthmusWeb.Admin.RadioChannels
  alias IsthmusWeb.Admin.UsbRole

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Isthmus.PubSub, "meshtastic:channels")
      Phoenix.PubSub.subscribe(Isthmus.PubSub, "meshtastic:lora")
      Phoenix.PubSub.subscribe(Isthmus.PubSub, "meshtastic:device")
      Phoenix.PubSub.subscribe(Isthmus.PubSub, BLESidecar.pin_topic())
      :timer.send_interval(5_000, self(), :refresh)
      BLERemembered.remember_healths(:meshtastic, Companion.list_health())
    end

    timezone =
      if connected?(socket) do
        get_connect_params(socket)["timezone"]
      end

    {:ok,
     socket
     |> assign(:page_title, "Meshtastic")
     |> assign(:channel_syncing, false)
     |> assign(:channel_sync_timed_out, false)
     |> assign(:settings_applying, false)
     |> assign(:time_syncing_port, nil)
     |> assign(:timezone, timezone)
     |> assign(:settings_modal_port, nil)
     |> assign(:channels_modal_id, nil)
     |> assign(:channel_invite, nil)
     |> assign(:send_channel, nil)
     |> assign(:send_form, to_form(%{"body" => ""}))
     |> assign(:settings_form, to_form(Settings.to_form_params(Settings.empty()), as: :settings))
     |> assign(:ble_scan, [])
     |> assign(:ble_scanning, false)
     |> assign(:ble_connecting, nil)
     |> assign(:ble_pin_prompt, nil)
     |> assign(:ble_pin_form, to_form(%{"pin" => "123456", "address" => ""}))
     |> FirmwareOffer.mount_assigns()
     |> refresh()}
  end

  @impl true
  def handle_event("sync_channels", %{"port" => port}, socket) do
    health = Companion.health(port)

    if health.status == :online do
      Companion.sync_channels_async(port)
      timeout = if health[:transport] == :ble, do: 35_000, else: 20_000
      Process.send_after(self(), :channel_sync_timeout, timeout)

      {:noreply,
       socket
       |> assign(:channel_syncing, true)
       |> assign(:channel_sync_timed_out, false)
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
    if ble_port?(port) and socket.assigns.ble_busy do
      {:noreply, socket}
    else
      Companion.reconnect(port)

      {:noreply,
       socket
       |> put_flash(:info, "Reconnecting Meshtastic companion…")
       |> refresh()}
    end
  end

  def handle_event("sync_time", %{"port" => port}, socket) do
    socket = assign(socket, :time_syncing_port, port)

    case Companion.set_time(port, tz: socket.assigns[:timezone]) do
      :ok ->
        {:noreply,
         socket
         |> assign(:time_syncing_port, nil)
         |> put_flash(:info, "Synced time and timezone to the radio.")
         |> refresh()}

      {:error, :not_connected} ->
        {:noreply,
         socket
         |> assign(:time_syncing_port, nil)
         |> put_flash(:error, "Meshtastic companion offline.")}

      {:error, :busy} ->
        {:noreply,
         socket
         |> assign(:time_syncing_port, nil)
         |> put_flash(:error, "Radio is busy with another admin request — try again in a moment.")}

      {:error, :timeout} ->
        {:noreply,
         socket
         |> assign(:time_syncing_port, nil)
         |> put_flash(:error, "Timed out setting radio time.")}

      {:error, :not_ready} ->
        {:noreply,
         socket
         |> assign(:time_syncing_port, nil)
         |> put_flash(:error, "Radio identity unknown — wait for node id, then retry.")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:time_syncing_port, nil)
         |> put_flash(:error, "Could not set radio time: #{inspect(reason)}")}
    end
  end

  def handle_event("scan_bluetooth", _params, socket) do
    if socket.assigns.ble_busy do
      {:noreply, socket}
    else
      lv = self()

      Task.start(fn ->
        send(lv, {:ble_scan_done, BLESidecar.scan(5_000)})
      end)

      {:noreply, socket |> assign(:ble_scanning, true) |> assign_ble_busy()}
    end
  end

  def handle_event("connect_ble", params, socket) do
    address = String.trim(to_string(params["address"] || ""))
    name = String.trim(to_string(params["name"] || ""))

    cond do
      address == "" ->
        {:noreply, put_flash(socket, :error, "Pick a Bluetooth radio from the scan list.")}

      socket.assigns.ble_busy ->
        {:noreply, socket}

      true ->
        opts = if name != "", do: [name: name], else: []

        case MeshtasticSupervisor.start_ble(address, nil, opts) do
          :ok ->
            {:noreply,
             socket
             |> assign(:ble_connecting, address)
             |> put_flash(
               :info,
               "Connecting — a PIN is only needed if this radio has not been paired yet."
             )
             |> refresh()}

          {:error, reason} ->
            {:noreply,
             put_flash(socket, :error, "Bluetooth connect failed: #{format_err(reason)}")}
        end
    end
  end

  def handle_event("submit_ble_pin", params, socket) do
    address =
      String.trim(
        to_string(params["address"] || get_in(socket.assigns, [:ble_pin_prompt, :address]) || "")
      )

    pin = params["pin"] |> to_string() |> String.trim()

    cond do
      address == "" ->
        {:noreply, put_flash(socket, :error, "Bluetooth pairing expired — Connect again.")}

      not String.match?(pin, ~r/^\d{4,8}$/) ->
        {:noreply,
         socket
         |> assign(:ble_pin_form, to_form(%{"pin" => pin, "address" => address}))
         |> put_flash(:error, "Enter the 4–8 digit PIN shown on the radio.")}

      true ->
        case BLESidecar.provide_pin(address, pin) do
          :ok ->
            {:noreply,
             socket
             |> assign(:ble_pin_prompt, nil)
             |> assign(:ble_pin_form, to_form(%{"pin" => "123456", "address" => ""}))
             |> put_flash(:info, "PIN sent — finishing Bluetooth pairing…")
             |> refresh()}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Could not send PIN: #{format_err(reason)}")}
        end
    end
  end

  def handle_event("cancel_ble_pin", _params, socket) do
    address =
      get_in(socket.assigns, [:ble_pin_prompt, :address]) || socket.assigns[:ble_connecting]

    if is_binary(address) and address != "" do
      _ = BLESidecar.cancel_pin(address)
      _ = MeshtasticSupervisor.stop_ble(address)
    end

    {:noreply,
     socket
     |> assign(:ble_pin_prompt, nil)
     |> assign(:ble_connecting, nil)
     |> assign(:ble_pin_form, to_form(%{"pin" => "123456", "address" => ""}))
     |> put_flash(:info, "Bluetooth pairing cancelled.")
     |> refresh()}
  end

  def handle_event("disconnect_ble", params, socket) do
    address = String.trim(to_string(params["address"] || params["port"] || ""))

    cond do
      address == "" ->
        {:noreply, put_flash(socket, :error, "No Bluetooth address on that radio.")}

      true ->
        _ = MeshtasticSupervisor.stop_ble(address)

        connecting =
          if socket.assigns[:ble_connecting] &&
               Companion.same_ble_address?(socket.assigns.ble_connecting, address),
             do: nil,
             else: socket.assigns[:ble_connecting]

        {:noreply,
         socket
         |> assign(:ble_connecting, connecting)
         |> put_flash(:info, "Disconnected Bluetooth companion.")
         |> refresh()}
    end
  end

  def handle_event("refresh_firmware_catalog", _params, socket) do
    send(self(), :refresh_firmware_catalog)
    {:noreply, assign(socket, :firmware_catalog_loading, true)}
  end

  def handle_event("assign_usb_board", params, socket) do
    id = params["device_id"] || params[:device_id]
    board = params["board"] || params[:board]
    {:noreply, FirmwareOffer.pick_board(socket, id, board)}
  end

  def handle_event("assign_usb_firmware", params, socket) do
    id = params["device_id"] || params[:device_id]
    kind = params["kind"] || params[:kind]

    case Enum.find(socket.assigns.devices, &(&1.id == id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Unknown device — rescan USB and try again.")}

      device ->
        case UsbRole.apply_firmware(device, kind) do
          {:ok, msg} ->
            {:noreply, socket |> put_flash(:info, msg) |> refresh()}

          {:error, msg} ->
            {:noreply, put_flash(socket, :error, msg)}
        end
    end
  end

  def handle_event("assign_usb_role", params, socket) do
    case UsbRole.apply_event(params) do
      {:ok, msg} ->
        {:noreply, socket |> put_flash(:info, msg) |> refresh()}

      {:error, msg} ->
        {:noreply, put_flash(socket, :error, msg)}
    end
  end

  def handle_event("rescan_devices", _params, socket) do
    case Discover.refresh() do
      {:ok, _roles} ->
        socket = refresh(socket)

        {:noreply, put_flash(socket, :info, meshtastic_rescan_flash(socket.assigns.devices))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Rescan failed: #{inspect(reason)}")}
    end
  end

  def handle_event("open_channels", params, socket) do
    id = params["device_id"] || params["device-id"]
    {:noreply, assign(socket, :channels_modal_id, id)}
  end

  def handle_event("close_channels", _params, socket) do
    {:noreply, assign(socket, :channels_modal_id, nil)}
  end

  def handle_event("open_device_config", %{"port" => port}, socket) do
    settings = %{
      lora: Companion.lora_config(port),
      device: Companion.device_config(port)
    }

    {:noreply,
     socket
     |> assign(:settings_modal_port, port)
     |> assign(:settings_form, to_form(Settings.to_form_params(settings), as: :settings))}
  end

  def handle_event("close_device_config", _params, socket) do
    {:noreply, assign(socket, :settings_modal_port, nil)}
  end

  def handle_event("validate_settings", %{"settings" => params}, socket) do
    {:noreply, assign(socket, :settings_form, to_form(params, as: :settings))}
  end

  def handle_event("save_settings", %{"settings" => params} = all, socket) do
    port = RadioChannels.blank_port(all["port"] || socket.assigns.settings_modal_port)
    socket = assign(socket, :settings_applying, true)

    case Companion.set_settings(params, port) do
      {:ok, applied} ->
        {:noreply,
         socket
         |> assign(:settings_applying, false)
         |> assign(:settings_modal_port, nil)
         |> assign(:settings_form, to_form(Settings.to_form_params(applied), as: :settings))
         |> put_flash(
           :info,
           "Device settings written — radio is rebooting and will reconnect shortly."
         )
         |> refresh()}

      {:error, :not_connected} ->
        {:noreply,
         socket
         |> assign(:settings_applying, false)
         |> put_flash(:error, "Meshtastic companion offline.")}

      {:error, :timeout} ->
        {:noreply,
         socket
         |> assign(:settings_applying, false)
         |> put_flash(:error, "Timed out talking to Meshtastic companion.")}

      {:error, :busy} ->
        {:noreply,
         socket
         |> assign(:settings_applying, false)
         |> put_flash(:error, "Radio is busy with another admin request — try again in a moment.")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:settings_applying, false)
         |> put_flash(:error, "Device settings failed: #{format_err(reason)}")}
    end
  end

  def handle_event("assign_slot_group", params, socket) do
    idx = RadioChannels.parse_slot(params["channel_idx"])
    port = RadioChannels.blank_port(params["port"])
    radio_id = Registrations.normalize_radio_id(params["radio_id"])
    group_id = String.trim(to_string(params["group_id"] || ""))
    current = RadioChannels.linked_group(socket.assigns.groups, idx, radio_id, "meshtastic")

    cond do
      idx not in 1..7 ->
        {:noreply,
         put_flash(socket, :error, "Pick a secondary slot (1–7). Slot 0 is PRIMARY / frequency.")}

      is_nil(radio_id) ->
        {:noreply,
         put_flash(socket, :error, "Radio identity unknown — wait for node id, then retry.")}

      group_id == "" and is_nil(current) ->
        {:noreply, socket}

      group_id == "" ->
        unlink_slot(socket, current, port, radio_id)

      current && current.id == group_id ->
        {:noreply, socket}

      RadioChannels.empty_channel?(Companion.list_channels(port), idx) ->
        provision_channel(socket, Registrations.get_group!(group_id), idx: idx, port: port)

      true ->
        link_occupied_slot(socket, group_id, idx, port, radio_id, current)
    end
  end

  def handle_event("show_channel_invite", params, socket) do
    group = Registrations.get_group!(params["id"])
    radio_id = Registrations.normalize_radio_id(params["radio_id"])

    case Registrations.meshtastic_channel_invite(group, device_id: radio_id) do
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

  def handle_event("open_send_channel", params, socket) do
    port = params["port"]
    idx = parse_channel_idx(params["channel_idx"])

    cond do
      is_nil(port) or port == "" or is_nil(idx) ->
        {:noreply, put_flash(socket, :error, "Missing radio or channel.")}

      true ->
        {:noreply,
         socket
         |> assign(:send_channel, %{
           port: port,
           channel_idx: idx,
           name: channel_send_name(port, idx)
         })
         |> assign(:send_form, to_form(%{"body" => ""}))}
    end
  end

  def handle_event("close_send_channel", _params, socket) do
    {:noreply, assign(socket, :send_channel, nil)}
  end

  def handle_event("send_channel_text", params, socket) do
    port = params["port"] || get_in(socket.assigns, [:send_channel, :port])

    idx =
      parse_channel_idx(
        params["channel_idx"] || get_in(socket.assigns, [:send_channel, :channel_idx])
      )

    body = params["body"] |> to_string() |> String.trim()
    name = get_in(socket.assigns, [:send_channel, :name]) || channel_send_name(port, idx)

    cond do
      body == "" ->
        {:noreply,
         socket
         |> assign(:send_form, to_form(%{"body" => ""}))
         |> put_flash(:error, "Message is empty.")}

      is_nil(port) or port == "" or is_nil(idx) ->
        {:noreply, put_flash(socket, :error, "Missing radio or channel.")}

      true ->
        case Companion.send_channel_text(idx, body, port) do
          :ok ->
            record_admin_channel_send(port, idx, body)

            {:noreply,
             socket
             |> assign(:send_channel, nil)
             |> assign(:send_form, to_form(%{"body" => ""}))
             |> put_flash(:info, "Sent to #{name}.")}

          {:error, reason}
          when reason in [:not_connected, :timeout, "not_connected", "disconnected"] ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "Bluetooth link dropped — Isthmus is reconnecting. Try Send again in a moment."
             )}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Send failed: #{format_err(reason)}")}
        end
    end
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, refresh(socket)}

  def handle_info(:refresh_firmware_catalog, socket) do
    {:noreply, FirmwareOffer.handle_refresh(socket)}
  end

  def handle_info({:meshtastic_channels, channels, _port}, socket) when is_list(channels) do
    socket =
      socket
      |> assign(:channel_syncing, false)
      |> refresh()

    socket =
      if socket.assigns[:channel_sync_timed_out] do
        socket
        |> assign(:channel_sync_timed_out, false)
        |> clear_flash(:error)
        |> put_flash(:info, "Channel list updated.")
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info(:channel_sync_timeout, socket) do
    if socket.assigns[:channel_syncing] do
      {:noreply,
       socket
       |> assign(:channel_syncing, false)
       |> assign(:channel_sync_timed_out, true)
       |> put_flash(
         :error,
         "Channel sync is still running — names may appear in a moment."
       )
       |> refresh()}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:meshtastic_lora, lora, port}, socket) when is_map(lora) do
    {:noreply, refresh_settings_form(socket, port, lora: lora)}
  end

  def handle_info({:meshtastic_device, device, port}, socket) when is_map(device) do
    {:noreply, refresh_settings_form(socket, port, device: device)}
  end

  def handle_info({:ble_pin_request, info}, socket) when is_map(info) do
    address = to_string(info[:address] || "")

    {:noreply,
     socket
     |> assign(:ble_connecting, address)
     |> assign(:ble_pin_prompt, info)
     |> assign(:ble_pin_form, to_form(%{"pin" => "123456", "address" => address}))
     |> refresh()}
  end

  def handle_info({:ble_scan_done, {:ok, devices}}, socket) do
    devices = Enum.filter(devices, &(&1[:kind] == :meshtastic))

    {:noreply,
     socket
     |> assign(:ble_scanning, false)
     |> assign(:ble_scan, devices)
     |> assign_ble_busy()}
  end

  def handle_info({:ble_scan_done, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:ble_scanning, false)
     |> assign_ble_busy()
     |> put_flash(:error, "Bluetooth scan failed: #{format_err(reason)}")}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp refresh(socket) do
    devices = Devices.inventory()
    claim_meshtastic_slots(devices)

    groups = Registrations.list_all()
    bridges = Enum.filter(groups, &(&1.kind == "bridge" and &1.status == "active"))

    connecting = socket.assigns[:ble_connecting]

    connecting =
      if is_binary(connecting) and
           Enum.any?(devices, fn d ->
             d[:ble?] == true and d[:active?] == true and
               Companion.same_ble_address?(d.ble_address, connecting)
           end) do
        nil
      else
        connecting
      end

    socket
    |> assign(:groups, groups)
    |> assign(:bridges, bridges)
    |> assign(:devices, devices)
    |> assign(:ble_connecting, connecting)
    |> assign(:settings_applying, socket.assigns[:settings_applying] || false)
    |> clear_missing_channels_modal(devices)
    |> assign_ble_busy()
  end

  defp clear_missing_channels_modal(socket, devices) do
    id = socket.assigns[:channels_modal_id]

    if is_binary(id) and not Enum.any?(devices, &(&1.id == id)) do
      assign(socket, :channels_modal_id, nil)
    else
      socket
    end
  end

  defp assign_ble_busy(socket) do
    devices = socket.assigns[:devices] || []

    busy =
      socket.assigns[:ble_scanning] == true or
        is_binary(socket.assigns[:ble_connecting]) or
        Enum.any?(devices, &ble_connecting_device?/1)

    online =
      devices
      |> Enum.filter(&(&1[:ble?] == true and &1[:active?] == true))
      |> Enum.map(&Companion.normalize_ble_address(&1.ble_address || ""))
      |> Enum.reject(&(&1 == ""))
      |> MapSet.new()

    socket
    |> assign(:ble_busy, busy)
    |> assign(:ble_online_addrs, online)
  end

  defp ble_connecting_device?(%{ble?: true, health: %{status: :connecting}}), do: true
  defp ble_connecting_device?(_), do: false

  defp refresh_settings_form(socket, port, _overrides) do
    socket = refresh(socket)

    if socket.assigns.settings_modal_port == port do
      settings = %{
        lora: Companion.lora_config(port),
        device: Companion.device_config(port)
      }

      assign(socket, :settings_form, to_form(Settings.to_form_params(settings), as: :settings))
    else
      socket
    end
  end

  defp claim_meshtastic_slots(devices) do
    Enum.each(devices, fn device ->
      radio_id = meshtastic_radio_id(device)
      occupied = RadioChannels.occupied_slot_indexes(device.channels)

      if radio_id && occupied != [] do
        Registrations.claim_unscoped_radio_channel(:meshtastic, radio_id, occupied)
      end
    end)
  end

  defp meshtastic_rescan_flash(devices) when is_list(devices) do
    found = Enum.filter(devices, &(is_binary(&1.path) and &1.path != ""))
    online = Enum.filter(found, & &1.active?)
    shown = if online == [], do: found, else: online

    case shown do
      [] ->
        "Rescanned — no Meshtastic companion found."

      [one] ->
        "Rescanned — Meshtastic companion on #{one.path}."

      many ->
        "Rescanned — #{length(many)} Meshtastic companions."
    end
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
           "Private Meshtastic channel created on slot #{Keyword.get(opts, :idx) || linked.meshtastic_channel_idx}."
         )
         |> refresh()}

      {:error, :not_connected} ->
        {:noreply, put_flash(socket, :error, "Meshtastic companion offline.")}

      {:error, :no_empty_channel_slot} ->
        {:noreply, put_flash(socket, :error, "No empty secondary channel slots (1–7).")}

      {:error, :slot_occupied} ->
        {:noreply, put_flash(socket, :error, "That slot is already configured on the radio.")}

      {:error, :already_linked} ->
        {:noreply,
         put_flash(socket, :error, "This group already has a Meshtastic channel on this radio.")}

      {:error, :timeout} ->
        recover_provision_timeout(socket, group, opts)

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not create channel: #{inspect(reason)}")}
    end
  end

  defp unlink_slot(socket, group, port, radio_id) do
    link = Registrations.radio_link(group, "meshtastic", radio_id)
    idx = link && link.channel_idx

    case clear_radio_slot(idx, port) do
      :ok ->
        finish_unlink(
          socket,
          group,
          radio_id,
          "Channel unlinked and slot #{idx} cleared on the radio."
        )

      {:error, :not_connected} ->
        finish_unlink(
          socket,
          group,
          radio_id,
          "Channel unlinked. Companion offline — the radio slot was not cleared."
        )

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Could not clear radio slot #{idx}: #{format_err(reason)}")}
    end
  end

  # BLE set_channel can finish after the LiveView call times out. If the slot
  # already shows the group name, finish the DB link instead of flashing failure.
  defp recover_provision_timeout(socket, group, opts) do
    idx = Keyword.get(opts, :idx)
    port = Keyword.get(opts, :port)
    expected = String.trim(to_string(Keyword.get(opts, :name) || group.display_name || "Channel"))
    slot = is_integer(idx) && Companion.get_channel(idx, port)
    got = slot && String.trim(to_string(slot[:name] || ""))
    hex = slot && (slot[:psk_hex] || slot[:secret_hex])
    radio_id = Registrations.normalize_radio_id(Companion.health(port)[:node_id])

    cond do
      is_map(slot) and not slot.empty? and got != "" and
        String.downcase(got) == String.downcase(expected) and
        is_binary(hex) and hex != "" ->
        case Registrations.link_meshtastic_channel(group, idx, hex, device_id: radio_id) do
          {:ok, _} ->
            {:noreply,
             socket
             |> assign(:channel_invite, nil)
             |> put_flash(:info, "Private Meshtastic channel created on slot #{idx}.")
             |> refresh()}

          {:error, :already_linked} ->
            {:noreply,
             socket
             |> put_flash(:info, "Private Meshtastic channel created on slot #{idx}.")
             |> refresh()}

          {:error, :channel_already_linked} ->
            {:noreply, put_flash(socket, :error, "Channel already linked to another group.")}

          {:error, reason} ->
            {:noreply,
             socket
             |> put_flash(
               :info,
               "Radio slot #{idx} was written, but linking did not finish (#{format_err(reason)}). Sync and assign again if needed."
             )
             |> refresh()}
        end

      true ->
        {:noreply, put_flash(socket, :error, "Timed out talking to Meshtastic companion.")}
    end
  end

  defp clear_radio_slot(idx, port) when is_integer(idx) and idx in 1..7 do
    case Companion.clear_channel(idx, port) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  defp clear_radio_slot(_, _), do: :ok

  defp finish_unlink(socket, group, radio_id, message) do
    {:ok, _} = Registrations.unlink_meshtastic_channel(group, device_id: radio_id)

    {:noreply,
     socket
     |> assign(:channel_invite, nil)
     |> put_flash(:info, message)
     |> refresh()}
  end

  defp link_occupied_slot(socket, group_id, idx, port, radio_id, current) do
    group = Registrations.get_group!(group_id)

    with :ok <- maybe_unlink(current, radio_id),
         %{psk_hex: psk} when is_binary(psk) and psk != "" <- Companion.get_channel(idx, port),
         {:ok, _} <-
           Registrations.link_meshtastic_channel(group, idx, psk, device_id: radio_id) do
      {:noreply,
       socket
       |> assign(:channel_invite, nil)
       |> put_flash(:info, "Channel #{idx} linked to #{group.display_name}.")
       |> refresh()}
    else
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

  defp maybe_unlink(nil, _), do: :ok

  defp maybe_unlink(group, radio_id) do
    {:ok, _} = Registrations.unlink_meshtastic_channel(group, device_id: radio_id)
    :ok
  end

  defp format_err(reason) when is_binary(reason), do: reason
  defp format_err(reason), do: inspect(reason)

  defp parse_channel_idx(n) when is_integer(n) and n in 0..7, do: n

  defp parse_channel_idx(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n in 0..7 -> n
      _ -> nil
    end
  end

  defp parse_channel_idx(_), do: nil

  defp ble_port?(port) when is_binary(port),
    do: String.starts_with?(String.downcase(port), "ble:")

  defp ble_port?(_), do: false

  defp channel_send_name(port, idx) do
    slot = if is_integer(idx), do: Companion.get_channel(idx, port)
    name = slot && String.trim(to_string(slot[:name] || slot["name"] || ""))

    cond do
      is_binary(name) and name != "" and
          String.downcase(name) not in ["channel", "primary", "primary channel"] ->
        name

      idx == 0 ->
        "Primary"

      is_integer(idx) ->
        "slot #{idx}"

      true ->
        "channel"
    end
  end

  defp record_admin_channel_send(port, idx, body) do
    health = Companion.health(port)

    _ =
      Messages.maybe_record_meshtastic_channel(%{
        channel_idx: idx,
        body: body,
        from_ref: health[:node_id] || health[:self_ref],
        force: idx == 0,
        meta: %{source: "admin_send", port: port}
      })
  end

  defp meshtastic_radio_id(arg), do: MeshtasticHTML.meshtastic_radio_id(arg)

  @impl true
  def render(assigns), do: MeshtasticHTML.page(assigns)
end
