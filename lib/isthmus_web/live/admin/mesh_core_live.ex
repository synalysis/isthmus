defmodule IsthmusWeb.Admin.MeshCoreLive do
  use IsthmusWeb, :live_view

  alias IsthmusWeb.Admin.MeshCoreHTML

  alias Isthmus.Networks.BLERemembered
  alias Isthmus.Networks.MeshCore.BLESidecar
  alias Isthmus.Networks.MeshCore.BridgeCLI
  alias Isthmus.Networks.MeshCore.BridgeLink
  alias Isthmus.Networks.MeshCore.Companion
  alias Isthmus.Networks.MeshCore.Devices
  alias Isthmus.Networks.MeshCore.Discover
  alias Isthmus.Networks.MeshCore.RadioParams
  alias Isthmus.Networks.MeshCore.Supervisor, as: MeshCoreSupervisor
  alias Isthmus.Networks.MeshCore.SyntheticNode
  alias Isthmus.Registrations
  alias IsthmusWeb.Admin.FirmwareOffer
  alias IsthmusWeb.Admin.RadioChannels
  alias IsthmusWeb.Admin.UsbRole

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Isthmus.PubSub, "meshcore:channels")
      Phoenix.PubSub.subscribe(Isthmus.PubSub, "meshcore:status")
      :timer.send_interval(5_000, self(), :refresh)
      BLERemembered.remember_healths(:meshcore, Companion.list_health())
    end

    {:ok,
     socket
     |> assign(:page_title, "MeshCore")
     |> assign(:channel_syncing, false)
     |> assign(:channel_invite, nil)
     |> assign(:radio_applying, false)
     |> assign(:radio_modal, nil)
     |> assign(:ports_modal_id, nil)
     |> assign(:synthetic_health, %{status: :unknown, identities: []})
     |> assign(:radio_form, to_form(RadioParams.empty_form_params(), as: :radio))
     |> assign(:ble_scan, [])
     |> assign(:ble_scanning, false)
     |> assign(:ble_connecting, nil)
     |> assign(:ble_pin, "123456")
     |> FirmwareOffer.mount_assigns()
     |> refresh()}
  end

  @impl true
  def handle_event("sync_meshcore_channels", params, socket) do
    port = RadioChannels.blank_port(params["port"])
    health = Companion.health(port)

    if health.status == :online do
      Companion.sync_channels_async(port)

      {:noreply,
       socket
       |> assign(:channel_syncing, true)
       |> assign(:companion_health, Companion.health())
       |> put_flash(:info, "Syncing MeshCore channels…")}
    else
      {:noreply,
       socket
       |> assign(:companion_health, Companion.health())
       |> put_flash(:error, "MeshCore companion offline — set ISTHMUS_MESHCORE_PORT.")}
    end
  end

  def handle_event("reconnect_companion", params, socket) do
    port = RadioChannels.blank_port(params["port"])

    if ble_port?(port) and socket.assigns.ble_busy do
      {:noreply, socket}
    else
      Companion.reconnect(port)

      {:noreply,
       socket
       |> put_flash(:info, "Reconnecting MeshCore companion…")
       |> refresh()}
    end
  end

  def handle_event("assign_slot_group", params, socket) do
    idx = RadioChannels.parse_slot(params["channel_idx"])
    radio_id = Registrations.normalize_radio_id(params["radio_id"])
    port = RadioChannels.blank_port(params["port"])
    group_id = String.trim(to_string(params["group_id"] || ""))
    current = RadioChannels.linked_group(socket.assigns.groups, idx, radio_id, "meshcore")

    cond do
      idx not in 1..7 ->
        {:noreply,
         put_flash(socket, :error, "Pick a private slot (1–7). Slot 0 is the public channel.")}

      is_nil(radio_id) ->
        {:noreply,
         put_flash(socket, :error, "Radio identity unknown — wait for the companion pubkey.")}

      group_id == "" and is_nil(current) ->
        {:noreply, socket}

      group_id == "" ->
        unlink_slot(socket, current, radio_id, port)

      current && current.id == group_id ->
        {:noreply, socket}

      RadioChannels.empty_channel?(Companion.list_channels(port), idx) ->
        provision_channel(socket, Registrations.get_group!(group_id), idx: idx, port: port)

      true ->
        link_occupied_slot(socket, group_id, idx, radio_id, current, port)
    end
  end

  def handle_event("show_channel_invite", params, socket) do
    group = Registrations.get_group!(params["id"])
    radio_id = Registrations.normalize_radio_id(params["radio_id"])

    case Registrations.meshcore_channel_invite(group, device_id: radio_id) do
      {:ok, invite} ->
        {:noreply, assign(socket, :channel_invite, invite)}

      {:error, :no_channel_linked} ->
        {:noreply, put_flash(socket, :error, "No MeshCore channel linked to this group.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not decrypt channel invite.")}
    end
  end

  def handle_event("hide_channel_invite", _params, socket) do
    {:noreply, assign(socket, :channel_invite, nil)}
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
    pin = String.trim(to_string(params["pin"] || socket.assigns.ble_pin || "123456"))

    cond do
      address == "" ->
        {:noreply, put_flash(socket, :error, "Pick a Bluetooth radio from the scan list.")}

      socket.assigns.ble_busy ->
        {:noreply, socket}

      true ->
        case MeshCoreSupervisor.start_ble(address, pin) do
          :ok ->
            {:noreply,
             socket
             |> assign(:ble_pin, pin)
             |> assign(:ble_connecting, address)
             |> put_flash(:info, "Connecting MeshCore Bluetooth companion…")
             |> refresh()}

          {:error, reason} ->
            {:noreply,
             put_flash(socket, :error, "Bluetooth connect failed: #{format_err(reason)}")}
        end
    end
  end

  def handle_event("disconnect_ble", params, socket) do
    address = String.trim(to_string(params["address"] || params["port"] || ""))

    cond do
      address == "" ->
        {:noreply, put_flash(socket, :error, "No Bluetooth address on that radio.")}

      true ->
        _ = MeshCoreSupervisor.stop_ble(address)

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
    {:noreply,
     socket
     |> assign(:firmware_catalog_loading, true)
     |> then(fn socket ->
       send(self(), :refresh_firmware_catalog)
       socket
     end)}
  end

  def handle_event("assign_usb_board", params, socket) do
    id = params["device_id"] || params[:device_id]
    board = params["board"] || params[:board]
    {:noreply, FirmwareOffer.pick_board(socket, id, board)}
  end

  def handle_event("pick_usb_firmware", params, socket) do
    id = params["device_id"] || params[:device_id]
    kind = params["kind"] || params[:kind]
    {:noreply, FirmwareOffer.pick_kind(socket, id, kind)}
  end

  def handle_event("install_firmware", params, socket) do
    {:noreply, FirmwareOffer.start_install(socket, params)}
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
      {:ok, roles} ->
        Process.send_after(self(), :refresh, 750)

        {:noreply,
         socket
         |> put_flash(:info, "Rescanned — #{format_roles_flash(roles)}")
         |> refresh()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Rescan failed: #{inspect(reason)}")}
    end
  end

  def handle_event("open_ports_channels", params, socket) do
    id = params["device_id"] || params["device-id"]
    {:noreply, assign(socket, :ports_modal_id, id)}
  end

  def handle_event("close_ports_channels", _params, socket) do
    {:noreply, assign(socket, :ports_modal_id, nil)}
  end

  def handle_event("open_radio_config", %{"device_id" => id}, socket) do
    case Enum.find(socket.assigns.devices, &(&1.id == id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "Unknown device — rescan USB and try again.")}

      device ->
        case radio_config_kind(device) do
          nil ->
            {:noreply, put_flash(socket, :error, "This radio has no settings to edit.")}

          kind ->
            health =
              if kind == :companion,
                do: device.companion_health,
                else: device.bridge_cli_health

            {:noreply,
             socket
             |> assign(:radio_modal, %{
               kind: kind,
               device_id: device.id,
               label: device.label
             })
             |> assign(:radio_form, to_form(radio_form_from_health(health), as: :radio))}
        end
    end
  end

  def handle_event("close_radio_config", _params, socket) do
    {:noreply, assign(socket, :radio_modal, nil)}
  end

  def handle_event("validate_radio", %{"radio" => params} = payload, socket) do
    params = RadioParams.apply_form_change(params, payload["_target"])

    {:noreply, assign(socket, :radio_form, to_form(params, as: :radio))}
  end

  def handle_event("save_companion_radio", %{"radio" => params} = payload, socket) do
    device_id = payload["device_id"]

    with :ok <- ensure_device_role(socket, device_id, :companion),
         :ok <- Companion.set_radio_params(params, companion_port_for(socket, device_id)),
         :ok <-
           Companion.set_tx_power(
             params["tx_power"] || params[:tx_power],
             companion_port_for(socket, device_id)
           ) do
      {:noreply,
       socket
       |> assign(:radio_modal, nil)
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
       |> assign(:radio_modal, nil)
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
  def handle_info({:meshcore_channels, channels, _port}, socket) when is_list(channels) do
    {:noreply,
     socket
     |> assign(:channel_syncing, false)
     |> refresh()
     |> put_flash(:info, "Synced #{length(channels)} MeshCore channel slots.")}
  end

  def handle_info({:meshcore_channels, channels}, socket) when is_list(channels) do
    handle_info({:meshcore_channels, channels, nil}, socket)
  end

  def handle_info(:refresh, socket), do: {:noreply, refresh(socket)}

  def handle_info({:firmware_flash, job}, socket) do
    {:noreply, FirmwareOffer.handle_flash_progress(socket, job)}
  end

  def handle_info(:refresh_firmware_catalog, socket) do
    {:noreply, FirmwareOffer.handle_refresh(socket)}
  end

  def handle_info({:meshcore_status, _kind, _health}, socket) do
    {:noreply, refresh(socket)}
  end

  def handle_info({:ble_scan_done, {:ok, devices}}, socket) do
    devices = Enum.reject(devices, &(&1[:kind] == :meshtastic))

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
    companions = Companion.list_health()
    claim_meshcore_slots(companions)

    groups = Registrations.list_all()
    bridges = Enum.filter(groups, &(&1.kind == "bridge" and &1.status == "active"))
    bridge_cli = BridgeCLI.health()
    bridge_link = BridgeLink.health()
    roles = Discover.roles()
    companion = Companion.health()

    devices =
      Devices.inventory(
        roles: roles,
        companions: companions,
        bridge_cli: bridge_cli,
        bridge_link: bridge_link
      )

    connecting = clear_ble_connecting(socket.assigns[:ble_connecting], devices)

    socket
    |> assign(:groups, groups)
    |> assign(:bridges, bridges)
    |> assign(:companion_health, companion)
    |> assign(:bridge_health, bridge_link)
    |> assign(:bridge_cli_health, bridge_cli)
    |> assign(:synthetic_health, SyntheticNode.health())
    |> assign(:discovered_roles, roles)
    |> assign(:devices, devices)
    |> assign(:ble_connecting, connecting)
    |> assign(:channel_syncing, socket.assigns[:channel_syncing] || false)
    |> assign(:radio_applying, socket.assigns[:radio_applying] || false)
    |> clear_missing_ports_modal(devices)
    |> assign_ble_busy()
  end

  defp clear_missing_ports_modal(socket, devices) do
    id = socket.assigns[:ports_modal_id]

    if is_binary(id) and not Enum.any?(devices, &(&1.id == id)) do
      assign(socket, :ports_modal_id, nil)
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
      |> Enum.filter(&(&1[:ble?] == true and &1[:active_companion?] == true))
      |> Enum.map(&Companion.ble_address(&1.ble_address || ""))
      |> Enum.reject(&(&1 == ""))
      |> MapSet.new()

    socket
    |> assign(:ble_busy, busy)
    |> assign(:ble_online_addrs, online)
  end

  defp ble_connecting_device?(%{ble?: true, companion_health: %{status: :connecting}}), do: true
  defp ble_connecting_device?(_), do: false

  defp clear_ble_connecting(address, devices) when is_binary(address) do
    if Enum.any?(devices, fn d ->
         d[:ble?] == true and d[:active_companion?] == true and
           Companion.same_ble_address?(d.ble_address, address)
       end) do
      nil
    else
      address
    end
  end

  defp clear_ble_connecting(_, _), do: nil

  defp claim_meshcore_slots(companions) when is_list(companions) do
    Enum.each(companions, fn companion ->
      radio_id = Registrations.normalize_radio_id(companion[:self_ref])
      occupied = RadioChannels.occupied_slot_indexes(Companion.list_channels(companion[:port]))

      if radio_id && occupied != [] do
        Registrations.claim_unscoped_radio_channel(:meshcore, radio_id, occupied)
      end
    end)
  end

  defp radio_form_from_health(health) when is_map(health) do
    if health[:freq_mhz] do
      RadioParams.to_form_params(health)
    else
      RadioParams.empty_form_params()
    end
  end

  defp radio_form_from_health(_), do: RadioParams.empty_form_params()

  defp ble_port?(port) when is_binary(port),
    do: String.starts_with?(String.downcase(port), "ble:")

  defp ble_port?(_), do: false

  defp format_err(reason) when is_binary(reason), do: reason
  defp format_err(reason), do: inspect(reason)

  defp format_roles_flash(roles) do
    formatted =
      Enum.flat_map(roles, fn
        {:companion_ports, list} when is_list(list) ->
          Enum.map(list, fn
            %{path: path} -> "companion @ #{path}"
            path when is_binary(path) -> "companion @ #{path}"
            _ -> nil
          end)
          |> Enum.reject(&is_nil/1)

        {role, %{path: path}} when role in [:bridge_cli, :bridge_packet] ->
          ["#{role} @ #{path}"]

        {:companion, _} ->
          []

        _ ->
          []
      end)

    if formatted == [], do: "no MeshCore devices found", else: Enum.join(formatted, ", ")
  end

  defp ensure_device_role(socket, device_id, role) when role in [:companion, :bridge_cli] do
    case Enum.find(socket.assigns[:devices] || [], &(&1.id == device_id)) do
      nil ->
        {:error, :unknown_device}

      device ->
        ok? =
          case role do
            :companion -> device.companion? and device.active_companion?
            :bridge_cli -> device.bridge_cli? and device.active_bridge_cli?
          end

        if ok?, do: :ok, else: {:error, :wrong_role}
    end
  end

  defp companion_port_for(socket, device_id) do
    case Enum.find(socket.assigns[:devices] || [], &(&1.id == device_id)) do
      device when is_map(device) -> companion_port(device)
      _ -> nil
    end
  end

  defp companion_port(device) when is_map(device) do
    get_in(device, [:companion_health, :port]) ||
      Enum.find_value(device.ports || [], fn
        %{role: :companion, path: path} when is_binary(path) and path != "" -> path
        _ -> nil
      end)
  end

  defp device_label(socket, device_id) do
    case Enum.find(socket.assigns[:devices] || [], &(&1.id == device_id)) do
      %{label: label} when is_binary(label) and label != "" -> label
      _ -> device_id || "device"
    end
  end

  defp provision_channel(socket, group, opts) do
    result =
      try do
        Registrations.provision_meshcore_channel(group, opts)
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
           "Private MeshCore channel created on slot #{Keyword.get(opts, :idx) || linked.meshcore_channel_idx}."
         )
         |> refresh()}

      {:error, :not_connected} ->
        {:noreply, put_flash(socket, :error, "MeshCore companion offline.")}

      {:error, :no_empty_channel_slot} ->
        {:noreply, put_flash(socket, :error, "No empty private channel slots (1–7).")}

      {:error, :slot_occupied} ->
        {:noreply, put_flash(socket, :error, "That slot is already configured on the radio.")}

      {:error, :already_linked} ->
        {:noreply,
         put_flash(socket, :error, "This group already has a MeshCore channel on this radio.")}

      {:error, :timeout} ->
        {:noreply, put_flash(socket, :error, "Timed out talking to MeshCore companion.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not create channel: #{inspect(reason)}")}
    end
  end

  defp unlink_slot(socket, group, radio_id, port) do
    link = Registrations.radio_link(group, "meshcore", radio_id)
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

  defp clear_radio_slot(idx, port) when is_integer(idx) and idx in 1..7 do
    case Companion.clear_channel(idx, port) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  defp clear_radio_slot(_, _), do: :ok

  defp finish_unlink(socket, group, radio_id, message) do
    {:ok, _} = Registrations.unlink_meshcore_channel(group, device_id: radio_id)

    {:noreply,
     socket
     |> assign(:channel_invite, nil)
     |> put_flash(:info, message)
     |> refresh()}
  end

  defp link_occupied_slot(socket, group_id, idx, radio_id, current, port) do
    group = Registrations.get_group!(group_id)

    with :ok <- maybe_unlink(current, radio_id),
         %{secret_hex: secret} when is_binary(secret) and secret != "" <-
           Companion.get_channel(idx, port),
         {:ok, _} <-
           Registrations.link_meshcore_channel(group, idx, secret, device_id: radio_id) do
      {:noreply,
       socket
       |> assign(:channel_invite, nil)
       |> put_flash(:info, "Channel #{idx} linked to #{group.display_name}.")
       |> refresh()}
    else
      nil ->
        {:noreply, put_flash(socket, :error, "Channel not in companion cache — sync first.")}

      %{secret_hex: _} ->
        {:noreply, put_flash(socket, :error, "Channel has no secret — pick a private slot.")}

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
    {:ok, _} = Registrations.unlink_meshcore_channel(group, device_id: radio_id)
    :ok
  end

  defp radio_config_kind(arg), do: MeshCoreHTML.radio_config_kind(arg)

  @impl true
  def render(assigns), do: MeshCoreHTML.page(assigns)
end
