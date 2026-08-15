defmodule Isthmus.MCP.Server do
  @moduledoc """
  MCP server for operator control of this Isthmus instance.
  """
  use ExMCP.Server.Handler
  use ExMCP.Server.DSL, name: "isthmus", version: "0.1.0"

  alias Isthmus.MCP.JSON
  alias Isthmus.MCP.Tools

  @instructions """
  You are operating an Isthmus instance: a bridge between MeshCore, Meshtastic,
  Reticulum (LXMF), Nostr, and ACP agents. Use these tools to inspect health,
  manage groups/members, inject messages, and change tunnels, relays, ACP agent, and policy.
  Use bluetooth_status, scan_bluetooth, connect_bluetooth, and disconnect_bluetooth
  to drive MeshCore/Meshtastic BLE companions. Identify groups by UUID or display
  name (e.g. "Lobby"). Never ask for vault secrets or nsecs; this API does not
  expose private keys.
  """

  def instructions, do: @instructions

  def child_spec(opts) do
    opts = Keyword.put_new(opts, :transport, :beam)

    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :temporary
    }
  end

  tool "health", "Network adapter health (MeshCore, Meshtastic, Reticulum, Nostr, ACP agent)" do
    annotations(readOnlyHint: true)

    run(fn args, state -> reply(Tools.health(args), state) end)
  end

  tool "list_groups", "List registration and bridge groups with members and radio channels" do
    annotations(readOnlyHint: true)

    run(fn args, state -> reply(Tools.list_groups(args), state) end)
  end

  tool "get_group", "Get one group by UUID or display name" do
    param(:group, :string, required: true, description: "Group UUID or display name")
    annotations(readOnlyHint: true)

    run(fn args, state -> reply(Tools.get_group(args), state) end)
  end

  tool "create_group", "Create a bridge group" do
    param(:name, :string, required: true, description: "Display name")
    param(:owner, :string, description: "Owner npub or hex; defaults to the first admin")

    run(fn args, state -> reply(Tools.create_group(args), state) end)
  end

  tool "attach_member", "Attach an identity (meshcore, reticulum, nostr, or agent) to a group" do
    param(:group, :string, required: true, description: "Group UUID or display name")
    param(:network, :string, required: true, description: "meshcore | reticulum | nostr | agent")

    param(:identity, :string,
      required: true,
      description: "Pubkey, npub, dest hash, or agent name"
    )

    run(fn args, state -> reply(Tools.attach_member(args), state) end)
  end

  tool "detach_member", "Detach an attached member from a group" do
    param(:group, :string, required: true)
    param(:identity, :string, required: true)
    param(:network, :string, description: "Optional network disambiguator")

    run(fn args, state -> reply(Tools.detach_member(args), state) end)
  end

  tool "inject_message",
       "Inject a message into a group (fans out to members and radio channels)" do
    param(:group, :string, required: true, description: "Group UUID or display name")
    param(:body, :string, required: true, description: "Plain-text body")

    run(fn args, state -> reply(Tools.inject_message(args), state) end)
  end

  tool "announce_group", "Announce announceable proxy legs for a group" do
    param(:group, :string, required: true)

    run(fn args, state -> reply(Tools.announce_group(args), state) end)
  end

  tool "mint_proxy", "Mint an Isthmus-owned proxy (reticulum, nostr, or meshcore) on a group" do
    param(:group, :string, required: true)
    param(:network, :string, required: true, description: "reticulum | nostr | meshcore")

    run(fn args, state -> reply(Tools.mint_proxy(args), state) end)
  end

  tool "set_group_store_messages",
       "Keep this group's message bodies on Messages after forwarding (off by default)" do
    param(:group, :string, required: true, description: "Group UUID or display name")
    param(:enabled, :boolean, required: true)

    run(fn args, state -> reply(Tools.set_group_store_messages(args), state) end)
  end

  tool "revoke_group", "Revoke a group" do
    param(:group, :string, required: true)

    run(fn args, state -> reply(Tools.revoke_group(args), state) end)
  end

  tool "list_adverts", "Recent heard identities (MeshCore adverts, RNS announces, NodeInfo)" do
    param(:network, :string, description: "Optional network filter")
    param(:limit, :integer, default: 50)
    annotations(readOnlyHint: true)

    run(fn args, state -> reply(Tools.list_adverts(args), state) end)
  end

  tool "list_messages",
       "Heard Public channel text and group messages for groups with retention on" do
    param(:network, :string, description: "Optional network filter")
    param(:kind, :string, description: "channel | group")
    param(:limit, :integer, default: 50)
    annotations(readOnlyHint: true)

    run(fn args, state -> reply(Tools.list_messages(args), state) end)
  end

  tool "list_tunnels", "List island tunnel peers" do
    annotations(readOnlyHint: true)

    run(fn args, state -> reply(Tools.list_tunnels(args), state) end)
  end

  tool "create_tunnel", "Add an island tunnel peer" do
    param(:name, :string, required: true)

    param(:payload_network, :string,
      required: true,
      description: "reticulum | meshcore | nostr | meshtastic"
    )

    param(:carrier_network, :string, required: true)
    param(:peer_ref, :string, required: true, description: "Remote identity on the carrier")
    param(:pairing_code, :string, description: "Shared code; both ends derive the same tunnel_id")
    param(:tunnel_id, :string, description: "Explicit 32-char hex tunnel id")

    run(fn args, state -> reply(Tools.create_tunnel(args), state) end)
  end

  tool "set_tunnel_enabled", "Enable or pause a tunnel peer" do
    param(:tunnel, :string, required: true, description: "Tunnel UUID, name, or tunnel_id")
    param(:enabled, :boolean, required: true)

    run(fn args, state -> reply(Tools.set_tunnel_enabled(args), state) end)
  end

  tool "list_relays", "List configured Nostr relays" do
    annotations(readOnlyHint: true)

    run(fn args, state -> reply(Tools.list_relays(args), state) end)
  end

  tool "create_relay", "Add a Nostr relay (ws:// or wss://)" do
    param(:url, :string, required: true)
    param(:enabled, :boolean, default: true)
    param(:read, :boolean, default: true)
    param(:write, :boolean, default: true)

    run(fn args, state -> reply(Tools.create_relay(args), state) end)
  end

  tool "list_timeline", "Ops timeline (sighting, governor, gateway)" do
    param(:kinds, {:array, :string}, default: [])
    param(:limit, :integer, default: 40)
    annotations(readOnlyHint: true)

    run(fn args, state -> reply(Tools.list_timeline(args), state) end)
  end

  tool "gateway_log", "Recent gateway forward log (no message bodies)" do
    param(:limit, :integer, default: 30)
    annotations(readOnlyHint: true)

    run(fn args, state -> reply(Tools.gateway_log(args), state) end)
  end

  tool "governor_drops", "Governor drop summary and stats" do
    annotations(readOnlyHint: true)

    run(fn args, state -> reply(Tools.governor_drops(args), state) end)
  end

  tool "get_policy", "Read policy settings and gateway direction keys" do
    annotations(readOnlyHint: true)

    run(fn args, state -> reply(Tools.get_policy(args), state) end)
  end

  tool "get_acp", "ACP agent command, working directory, and connection status" do
    annotations(readOnlyHint: true)

    run(fn args, state -> reply(Tools.get_acp(args), state) end)
  end

  tool "set_acp",
       "Set the ACP agent command (Cursor, Hermes, Gemini, OpenCode, …) and reconnect" do
    param(:enabled, :boolean, description: "Whether to spawn the ACP subprocess")
    param(:command, :string, description: "Executable and args, e.g. hermes acp")
    param(:cwd, :string, description: "Working directory for ACP sessions")

    param(:preset, :string,
      description:
        "cursor | hermes | gemini | opencode | goose | copilot | cline | qwen | auggie | custom"
    )

    run(fn args, state -> reply(Tools.set_acp(args), state) end)
  end

  tool "set_policy", "Write a policy key (registration_open, budgets, gateway directions, …)" do
    param(:key, :string, required: true)
    param(:value, :string, required: true, description: "JSON or plain value")

    run(fn args, state -> reply(Tools.set_policy(decode_policy_value(args)), state) end)
  end

  tool "list_radios", "MeshCore and Meshtastic companion health" do
    annotations(readOnlyHint: true)

    run(fn args, state -> reply(Tools.list_radios(args), state) end)
  end

  tool "bluetooth_status",
       "BLE sidecar, adapter discovering/paired devices, and remembered companions" do
    annotations(readOnlyHint: true)

    run(fn args, state -> reply(Tools.bluetooth_status(args), state) end)
  end

  tool "scan_bluetooth", "Scan for MeshCore and Meshtastic Bluetooth radios" do
    param(:timeout_ms, :integer, default: 5000, description: "Scan window, 500–15000")
    annotations(readOnlyHint: true)

    run(fn args, state -> reply(Tools.scan_bluetooth(args), state) end)
  end

  tool "connect_bluetooth", "Start a MeshCore or Meshtastic BLE companion" do
    param(:network, :string, required: true, description: "meshtastic or meshcore")
    param(:address, :string, required: true, description: "Bluetooth MAC address")
    param(:pin, :string, description: "Pairing PIN; omit unless the radio is prompting")
    param(:name, :string, description: "Optional advertised name to remember")
    param(:wait_ms, :integer,
      default: 0,
      description: "Wait up to 15s for online; omit and poll list_radios instead"
    )

    run(fn args, state -> reply(Tools.connect_bluetooth(args), state) end)
  end

  tool "disconnect_bluetooth", "Stop a BLE companion and forget it across restarts" do
    param(:network, :string, required: true, description: "meshtastic or meshcore")
    param(:address, :string, required: true, description: "Bluetooth MAC address")

    run(fn args, state -> reply(Tools.disconnect_bluetooth(args), state) end)
  end

  tool "set_meshtastic_time", "Sync Unix time (and optional POSIX tzdef) to a Meshtastic radio" do
    param(:port, :string, description: "Serial port; omit for the primary radio")
    param(:timezone, :string, description: "IANA timezone, e.g. America/New_York")

    run(fn args, state -> reply(Tools.set_meshtastic_time(args), state) end)
  end

  tool "set_meshtastic_settings",
       "Write Meshtastic companion settings (buzzer, LoRa, …) and reboot" do
    param(:port, :string, description: "Serial port; omit for the primary radio")

    param(:buzzer_mode, :string,
      description: "enabled | disabled | notifications_only | system_only | direct_msg_only"
    )

    run(fn args, state -> reply(Tools.set_meshtastic_settings(args), state) end)
  end

  tool "topology", "Whole-bridge topology graph (groups, networks, tunnels)" do
    annotations(readOnlyHint: true)

    run(fn args, state -> reply(Tools.topology(args), state) end)
  end

  tool "list_admins", "Admin allowlist (npub / label)" do
    annotations(readOnlyHint: true)

    run(fn args, state -> reply(Tools.list_admins(args), state) end)
  end

  resource "isthmus://health", "Current adapter health" do
    mime_type("application/json")

    read(fn _params, state ->
      {:ok, data} = Tools.health(%{})
      {:ok, %{text: JSON.encode(data)}, state}
    end)
  end

  resource "isthmus://groups", "Bridge and registration groups" do
    mime_type("application/json")

    read(fn _params, state ->
      {:ok, data} = Tools.list_groups(%{})
      {:ok, %{text: JSON.encode(data)}, state}
    end)
  end

  defp reply({:ok, data}, state), do: {:ok, JSON.encode(data), state}
  defp reply({:error, reason}, state), do: {:ok, ToolResult.error(reason), state}

  defp decode_policy_value(args) do
    value = Map.get(args, :value) || Map.get(args, "value")

    parsed =
      cond do
        is_binary(value) ->
          case Jason.decode(value) do
            {:ok, decoded} -> decoded
            _ -> value
          end

        true ->
          value
      end

    Map.put(args, :value, parsed)
  end
end
