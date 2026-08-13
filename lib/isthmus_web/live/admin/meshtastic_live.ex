defmodule IsthmusWeb.Admin.MeshtasticLive do
  use IsthmusWeb, :live_view

  alias IsthmusWeb.Admin.MeshtasticHTML

  alias Isthmus.Networks.MeshCore.Discover
  alias Isthmus.Networks.Meshtastic.Companion
  alias Isthmus.Networks.Meshtastic.Devices
  alias Isthmus.Networks.Meshtastic.Settings
  alias Isthmus.Registrations
  alias IsthmusWeb.Admin.RadioChannels

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Isthmus.PubSub, "meshtastic:channels")
      Phoenix.PubSub.subscribe(Isthmus.PubSub, "meshtastic:lora")
      Phoenix.PubSub.subscribe(Isthmus.PubSub, "meshtastic:device")
      :timer.send_interval(5_000, self(), :refresh)
    end

    timezone =
      if connected?(socket) do
        get_connect_params(socket)["timezone"]
      end

    {:ok,
     socket
     |> assign(:page_title, "Meshtastic")
     |> assign(:channel_syncing, false)
     |> assign(:settings_applying, false)
     |> assign(:time_syncing_port, nil)
     |> assign(:timezone, timezone)
     |> assign(:settings_modal_port, nil)
     |> assign(:channel_invite, nil)
     |> assign(:settings_form, to_form(Settings.to_form_params(Settings.empty()), as: :settings))
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

  def handle_event("rescan_devices", _params, socket) do
    case Discover.refresh() do
      {:ok, _roles} ->
        socket = refresh(socket)

        {:noreply, put_flash(socket, :info, meshtastic_rescan_flash(socket.assigns.devices))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Rescan failed: #{inspect(reason)}")}
    end
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

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, refresh(socket)}

  def handle_info({:meshtastic_channels, channels, _port}, socket) when is_list(channels) do
    {:noreply, socket |> assign(:channel_syncing, false) |> refresh()}
  end

  def handle_info({:meshtastic_lora, lora, port}, socket) when is_map(lora) do
    {:noreply, refresh_settings_form(socket, port, lora: lora)}
  end

  def handle_info({:meshtastic_device, device, port}, socket) when is_map(device) do
    {:noreply, refresh_settings_form(socket, port, device: device)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp refresh(socket) do
    devices = Devices.inventory()
    claim_meshtastic_slots(devices)

    groups = Registrations.list_all()
    bridges = Enum.filter(groups, &(&1.kind == "bridge" and &1.status == "active"))

    socket
    |> assign(:groups, groups)
    |> assign(:bridges, bridges)
    |> assign(:devices, devices)
    |> assign(:settings_applying, socket.assigns[:settings_applying] || false)
  end

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
        {:noreply, put_flash(socket, :error, "Timed out talking to Meshtastic companion.")}

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

  defp meshtastic_radio_id(arg), do: MeshtasticHTML.meshtastic_radio_id(arg)

  @impl true
  def render(assigns), do: MeshtasticHTML.page(assigns)
end
