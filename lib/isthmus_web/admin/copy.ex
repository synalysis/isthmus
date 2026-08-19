defmodule IsthmusWeb.Admin.Copy do
  @moduledoc """
  Shared plain-language copy for admin network pages.

  Principles (apply on MeshCore, Groups, and later Reticulum / Nostr / Tunnels):

  1. **Purpose before plumbing** — lead with what the thing does; USB paths / ids under details.
  2. **One job per section** — radios ≠ mesh traffic ≠ groups/channels ≠ tunnel peers.
  3. **Nest dependents** — panes sit under the thing they need.
  4. **Plain status + next step** — Connected / Offline / Not identified; never raw `disabled`.
  5. **Stable glossary**
     * **Group** — Isthmus fan-out membership (DB may still say `kind: "bridge"`)
     * **Private MeshCore channel** — companion radio slot linked to a group
     * **Private Meshtastic channel** — companion radio slot linked to a group
     * **Island tunnel radio** — dual-CDC bridge-firmware repeater
     * **Companion radio** — channels / DMs / contacts
     * **Tunnel** — Isthmus peer carrying payload over a carrier
  """

  @doc "User-facing status for process/link health atoms."
  def status_plain(:online), do: "Connected"
  def status_plain(:connecting), do: "Connecting"
  def status_plain(:disabled), do: "Offline"
  def status_plain(:disconnected), do: "Offline"
  def status_plain(:down), do: "Offline"
  def status_plain(:error), do: "Error"
  def status_plain(:unknown), do: "Unknown"

  def status_plain(other) when is_atom(other),
    do: other |> Atom.to_string() |> String.capitalize()

  def status_plain(other) when is_binary(other), do: String.capitalize(other)
  def status_plain(_), do: "Unknown"

  def status_badge_class(:online), do: "badge-success"
  def status_badge_class(:connecting), do: "badge-info"
  def status_badge_class(:disabled), do: "badge-ghost"
  def status_badge_class(:disconnected), do: "badge-warning"
  def status_badge_class(:error), do: "badge-error"
  def status_badge_class(_), do: "badge-ghost"

  @doc "Purpose title + one-line blurb for a MeshCore device inventory row."
  def device_purpose(device) do
    cond do
      bootloader_usb?(device) ->
        {"USB bootloader", "Not running companion firmware Isthmus can use"}

      usb_permission_denied?(device) ->
        {"USB permission denied", "The container cannot open this serial port"}

      device[:usb_role] == :ignore or ignore_port?(device) ->
        {"Ignored USB port", "Isthmus will not open this port"}

      device[:ble?] == true or device[:kind] == :companion ->
        blurb =
          if device[:ble?] == true,
            do: "Bluetooth companion — channels, DMs, and contact sync",
            else: "Channels, DMs, and contact sync"

        {"Companion radio", blurb}

      device[:kind] == :meshtastic ->
        blurb =
          if device[:ble?] == true,
            do: "Bluetooth companion — private channels and LoRa configuration",
            else: "Private channels and LoRa configuration"

        {"Companion radio", blurb}

      device[:kind] == :bridge_repeater ->
        {"Island tunnel radio", "Carries MeshCore mesh traffic for tunnels"}

      true ->
        {"USB serial port",
         "Choose the firmware on this radio — Isthmus then classifies the USB ports"}
    end
  end

  defp ignore_port?(device) when is_map(device) do
    ports = List.wrap(device[:ports])

    cond do
      ports == [] -> false
      true -> Enum.all?(ports, &(&1[:role] == :ignore))
    end
  end

  @doc "True when USB still enumerates as a UF2 / DFU bootloader CDC."
  def bootloader_usb?(device) when is_map(device) do
    [device[:description], device[:label]]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" ")
    |> String.downcase()
    |> String.contains?("boot")
  end

  def bootloader_usb?(_), do: false

  @doc "True when Discover could not open the USB node (typical Docker nobody vs dialout)."
  def usb_permission_denied?(device) when is_map(device) do
    case device[:probe_error] do
      :eacces -> true
      :eperm -> true
      {:error, :eacces} -> true
      {:error, :eperm} -> true
      _ -> false
    end
  end

  def usb_permission_denied?(_), do: false

  @doc "Overall device status chip."
  def device_status(%{kind: :meshtastic, health: health}) when is_map(health) do
    status = health[:status] || :unknown
    {status, status_plain(status)}
  end

  def device_status(device) when is_map(device) do
    cond do
      device[:active_companion?] == true or device[:active_bridge_cli?] == true or
          device[:active_bridge_link?] == true ->
        {:online, "Connected"}

      bootloader_usb?(device) ->
        {:unknown, "Bootloader"}

      device[:kind] == :unknown ->
        {:unknown, "Needs firmware"}

      is_map(device[:companion_health]) and device[:companion_health][:status] == :error ->
        {:error, "Error"}

      true ->
        {:disabled, "Offline"}
    end
  end

  def role_plain(:companion), do: "Companion port"
  def role_plain(:meshtastic), do: "Companion port"
  def role_plain(:bridge_cli), do: "Config port"
  def role_plain(:bridge_packet), do: "Mesh traffic port"
  def role_plain(:rnode), do: "RNode"
  def role_plain(:ignore), do: "Ignored"
  def role_plain(_), do: "No role yet"

  def role_used_for(:companion), do: "Channels, DMs, contact sync"
  def role_used_for(:meshtastic), do: "Channels, DMs, LoRa config"
  def role_used_for(:bridge_cli), do: "Radio frequency and TX settings"
  def role_used_for(:bridge_packet), do: "Mesh traffic for tunnels and group contacts"
  def role_used_for(:rnode), do: "Reticulum interface"
  def role_used_for(:ignore), do: "Isthmus will not open this port"
  def role_used_for(_), do: "Choose a USB role, then Apply"

  @doc "Short USB node name (`ttyACM0`), or nil for Bluetooth keys."
  def usb_device_name(path) when is_binary(path) do
    cond do
      String.starts_with?(path, "ble:") -> nil
      String.starts_with?(path, "BLE:") -> nil
      true -> Path.basename(path)
    end
  end

  def usb_device_name(_), do: nil

  @doc "DB group kind → user-facing label."
  def group_kind_label("bridge"), do: "group"
  def group_kind_label(other) when is_binary(other), do: other
  def group_kind_label(_), do: "group"
end
