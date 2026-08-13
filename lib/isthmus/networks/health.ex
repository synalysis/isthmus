defmodule Isthmus.Networks.Health do
  @moduledoc """
  Normalizes adapter health maps into UI-friendly reports with actionable fixes.
  """

  alias Isthmus.Networks

  @display_order [:meshcore, :nostr, :reticulum, :meshtastic]

  @doc "Ordered list of normalized health reports for all adapters."
  def report_all do
    raw = Networks.health_all()

    @display_order
    |> Enum.filter(&Map.has_key?(raw, &1))
    |> Enum.map(fn id -> normalize(id, Map.fetch!(raw, id)) end)
  end

  @doc "Normalize one adapter health map."
  def normalize(network, health) when is_map(health) do
    status = normalize_status(health[:status] || health["status"])
    last_error = health[:last_error] || health["last_error"]
    {issue, fix} = diagnose(network, status, health, last_error)
    severity = severity(status, issue)

    %{
      network: network,
      label: label(network),
      status: status,
      severity: severity,
      summary: summary(network, status, health),
      issue: issue,
      fix: fix,
      detail: health[:detail] || health["detail"],
      meta: meta_lines(network, health)
    }
  end

  defp label(:meshcore), do: "MeshCore"
  defp label(:nostr), do: "Nostr"
  defp label(:reticulum), do: "Reticulum"
  defp label(:meshtastic), do: "Meshtastic"
  defp label(other), do: other |> to_string() |> String.capitalize()

  defp normalize_status(nil), do: :unknown
  defp normalize_status(s) when is_atom(s), do: s

  defp normalize_status(s) when is_binary(s) do
    try do
      String.to_existing_atom(s)
    rescue
      ArgumentError -> :unknown
    end
  end

  defp severity(status, issue)
       when is_binary(issue) and status in [:online, :starting, :connecting, :reconnecting],
       do: :warn

  defp severity(_status, issue) when is_binary(issue), do: :error
  defp severity(:live, _), do: :ok
  defp severity(:online, _), do: :ok
  defp severity(:running, _), do: :ok
  defp severity(:stub, _), do: :info
  defp severity(:disabled, _), do: :info
  defp severity(:reconnecting, _), do: :warn
  defp severity(:connecting, _), do: :warn
  defp severity(:starting, _), do: :warn
  defp severity(:disconnected, _), do: :warn
  defp severity(:error, _), do: :error
  defp severity(:crashed, _), do: :error
  defp severity(:not_started, _), do: :error
  defp severity(:down, _), do: :error
  defp severity(_, _), do: :warn

  defp summary(:meshcore, :online, health) do
    port = health[:port] || health["port"]
    transport = health[:transport] || health["transport"] || :usb
    "Companion online (#{transport}#{if port, do: " · #{port}", else: ""})"
  end

  defp summary(:meshcore, :disabled, _), do: "Companion disabled — no port configured"

  defp summary(:meshcore, status, health) do
    port = health[:port] || health["port"]
    "Companion #{status}" <> if(port, do: " · #{port}", else: "")
  end

  defp summary(:nostr, status, health) do
    online = health[:online] || 0
    enabled = health[:relays_enabled] || health[:relays_configured] || 0
    events = health[:events_seen] || 0
    "Relay pool #{status} · #{online}/#{enabled} online · #{events} events"
  end

  defp summary(:reticulum, :live, health) do
    registered = get_in(health, [:meta, "registered_count"]) || health[:registered_count]
    base = "RNS/LXMF sidecar live"
    if is_integer(registered), do: "#{base} · #{registered} identities", else: base
  end

  defp summary(:reticulum, :online, %{live: false} = health) do
    if err = health[:last_error] || health["last_error"] do
      "RNS sidecar up but not live: #{err}"
    else
      "RNS sidecar online — waiting for LXMF hello"
    end
  end

  defp summary(:reticulum, :online, _), do: "RNS sidecar online"
  defp summary(:reticulum, :stub, _), do: "Sidecar in stub mode (no live RNS)"
  defp summary(:reticulum, :starting, _), do: "RNS sidecar starting"
  defp summary(:reticulum, status, _), do: "Sidecar #{status}"

  defp summary(:meshtastic, :online, health) do
    port = health[:port] || health["port"]
    node = health[:node_id] || health["node_id"]
    base = "Companion online" <> if(port, do: " · #{port}", else: "")
    if is_binary(node) and node != "", do: "#{base} · !#{node}", else: base
  end

  defp summary(:meshtastic, :disabled, _),
    do: "Companion offline — plug in a radio or set ISTHMUS_MESHTASTIC_PORT"

  defp summary(:meshtastic, :stub, _), do: "Adapter stub — radio not wired yet"

  defp summary(:meshtastic, status, health) do
    port = health[:port] || health["port"]
    "Companion #{status}" <> if(port, do: " · #{port}", else: "")
  end

  defp summary(_net, status, _), do: "Status: #{status}"

  defp diagnose(:meshcore, _status, health, last_error) do
    port = health[:port] || health["port"] || System.get_env("ISTHMUS_MESHCORE_PORT")
    err = to_string(last_error || "")

    cond do
      health[:status] in [:disabled, "disabled"] ->
        {nil, "Set ISTHMUS_MESHCORE_PORT (try `mix isthmus.meshcore.ports`) and restart."}

      String.contains?(err, "eacces") or String.contains?(err, ":eacces") ->
        {"Permission denied opening #{port || "serial port"}",
         "Your user must be in the dialout group, and the running session must have picked that up. " <>
           "If you already ran `sudo usermod -aG dialout $USER`, fully log out/in (or reboot), " <>
           "confirm with `groups`, then restart Isthmus. Shortcut without logout: " <>
           "`sg dialout -c './bin/dev'`."}

      String.contains?(err, "enoent") ->
        {"Serial device not found (#{port})",
         "Unplug/replug the radio, then run `mix isthmus.meshcore.ports` and update ISTHMUS_MESHCORE_PORT."}

      String.contains?(err, "ebusy") ->
        {"Serial port busy (#{port})",
         "Close other apps using the port (serial monitors, another Isthmus/MeshCore process), then retry."}

      String.contains?(err, "ble_not_implemented") ->
        {"BLE transport is not implemented yet",
         "Use ISTHMUS_MESHCORE_TRANSPORT=usb with a USB companion, or wait for BLE support."}

      is_binary(last_error) and last_error != "" and health[:status] not in [:online, "online"] ->
        {"Companion error: #{last_error}",
         "Check the device cable/port and companion firmware, then restart the MeshCore adapter."}

      health[:status] in [:error, :disconnected, "error", "disconnected"] ->
        {"MeshCore companion is not connected",
         "Verify ISTHMUS_MESHCORE_PORT and that the radio is plugged in."}

      true ->
        {nil, nil}
    end
  end

  defp diagnose(:nostr, status, health, _last_error) do
    online = health[:online] || 0
    enabled = health[:relays_enabled] || 0

    cond do
      enabled == 0 ->
        {"No Nostr relays configured", "Add a wss:// relay under Admin → Nostr."}

      online == 0 and enabled > 0 ->
        {"No relays are online",
         "Check relay URLs and network access on Admin → Relays (status badges show per-relay errors)."}

      status in [:reconnecting, :starting] ->
        {"Relay pool is still connecting", nil}

      true ->
        {nil, nil}
    end
  end

  defp diagnose(:reticulum, status, health, last_error) do
    err = last_error || health[:last_error] || health["last_error"]
    live? = health[:live] == true

    cond do
      status == :stub ->
        {"RNS/LXMF packages not active",
         "Install with `pip install -r sidecar/requirements.txt` (rns + lxmf), then restart Isthmus."}

      status in [:crashed, :error] ->
        {"RNS sidecar unhealthy",
         err ||
           "Check ISTHMUS_RNS_SIDECAR path and python3 availability. See logs for sidecar exit."}

      status == :not_started ->
        {"RNS sidecar not started", "Restart Isthmus and check logs for sidecar spawn errors."}

      status == :starting ->
        {"RNS sidecar is still starting",
         "Wait a few seconds; if this persists, check python3 and sidecar logs."}

      status == :online and not live? and is_binary(err) and err != "" ->
        {"RNS sidecar failed to go live",
         "#{err} — often a config/loglevel issue under ISTHMUS_RNS_CONFIGDIR (~/.isthmus/reticulum). Restart after fixing."}

      status == :online and not live? ->
        {"Waiting for RNS/LXMF hello",
         "Sidecar process is up but has not finished booting RNS. Check logs for `RNS sidecar hello`; ensure `pip install rns lxmf` succeeded for the same python3 Isthmus uses."}

      status == :live and not live? ->
        {"RNS reported inconsistent live state", err || "Restart Isthmus and check sidecar logs."}

      true ->
        {nil, nil}
    end
  end

  defp diagnose(:meshtastic, :stub, _, _),
    do: {nil, "See docs/guides/meshtastic_adapter.md to wire a live radio."}

  defp diagnose(:meshtastic, _status, health, last_error) do
    port = health[:port] || health["port"] || System.get_env("ISTHMUS_MESHTASTIC_PORT")
    err = to_string(last_error || "")

    cond do
      health[:status] in [:disabled, "disabled"] ->
        {nil,
         "Plug in a Meshtastic companion (USB serial API) and Rescan, or pin ISTHMUS_MESHTASTIC_PORT."}

      String.contains?(err, "eacces") or String.contains?(err, ":eacces") ->
        {"Permission denied opening #{port || "serial port"}",
         "Your user must be in the dialout group. Confirm with `groups`, then restart Isthmus. " <>
           "Shortcut without logout: `sg dialout -c './bin/dev'`."}

      health[:status] in [:error, :disconnected, "error", "disconnected"] ->
        {"Meshtastic companion not connected",
         "Rescan USB on Admin → Meshtastic, or pin ISTHMUS_MESHTASTIC_PORT if several serial devices are attached."}

      true ->
        {nil, nil}
    end
  end

  defp diagnose(_, _, _, _), do: {nil, nil}

  defp meta_lines(:meshcore, health) do
    [
      {"Transport", health[:transport]},
      {"Port", health[:port]},
      {"BLE", health[:ble_address]}
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
  end

  defp meta_lines(:nostr, health) do
    [
      {"Connections", health[:connections]},
      {"Online", health[:online]},
      {"Enabled relays", health[:relays_enabled] || health[:relays_configured]}
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp meta_lines(:reticulum, health) do
    meta = health[:meta] || %{}

    [
      {"Live", health[:live]},
      {"Config", health[:configdir] || meta["configdir"]},
      {"RNS", meta["rns_version"]},
      {"LXMF", meta["lxmf_version"]},
      {"Socket", interface_socket_path()},
      {"Error", health[:last_error]}
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
  end

  defp meta_lines(:meshtastic, health) do
    [
      {"Port", health[:port]},
      {"Node", health[:node_id] && "!#{health[:node_id]}"},
      {"Region", health[:status] in [:online, "online"] && health[:region_label]},
      {"Modem", health[:status] in [:online, "online"] && health[:modem_preset_label]},
      {"Sent", health[:sent]},
      {"Received", health[:received]}
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
  end

  defp meta_lines(_, _), do: []

  defp interface_socket_path do
    try do
      Isthmus.Networks.Reticulum.InterfaceSocket.health()[:path]
    catch
      :exit, _ -> nil
    end
  end
end
