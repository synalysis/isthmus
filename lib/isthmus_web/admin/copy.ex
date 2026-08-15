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
  def status_badge_class(:disabled), do: "badge-ghost"
  def status_badge_class(:disconnected), do: "badge-warning"
  def status_badge_class(:error), do: "badge-error"
  def status_badge_class(_), do: "badge-ghost"

  @doc "Purpose title + one-line blurb for a MeshCore device inventory row."
  def device_purpose(device) do
    cond do
      bootloader_usb?(device) ->
        {"USB bootloader", "Not running companion firmware Isthmus can use"}

      device[:kind] == :companion ->
        {"Companion radio", "Channels, DMs, and contact sync"}

      device[:kind] == :meshtastic ->
        {"Companion radio", "Private channels and LoRa configuration"}

      device[:kind] == :bridge_repeater ->
        {"Island tunnel radio", "Carries MeshCore mesh traffic for tunnels"}

      true ->
        {"Radio not identified", "Plug in or power on, then Rescan USB"}
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
        {:unknown, "Not identified"}

      true ->
        {:disabled, "Offline"}
    end
  end

  def role_plain(:companion), do: "Companion port"
  def role_plain(:meshtastic), do: "Companion port"
  def role_plain(:bridge_cli), do: "Config port"
  def role_plain(:bridge_packet), do: "Mesh traffic port"
  def role_plain(_), do: "Not identified yet"

  def role_used_for(:companion), do: "Channels, DMs, contact sync"
  def role_used_for(:meshtastic), do: "Channels, DMs, LoRa config"
  def role_used_for(:bridge_cli), do: "Radio frequency and TX settings"
  def role_used_for(:bridge_packet), do: "Mesh traffic for tunnels and group contacts"
  def role_used_for(_), do: "Waiting for Rescan to identify this port"

  @doc "DB group kind → user-facing label."
  def group_kind_label("bridge"), do: "group"
  def group_kind_label(other) when is_binary(other), do: other
  def group_kind_label(_), do: "group"
end
