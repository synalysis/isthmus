defmodule Isthmus.Networks.Supervisor do
  @moduledoc "Network adapters and transport processes."
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: Isthmus.Networks.Nostr.Registry},
      Isthmus.Announce.Governor,
      Isthmus.Tunnel.Engine,
      Isthmus.Networks.Reticulum.InterfaceSocket,
      Isthmus.Networks.Firmware.Catalog,
      # Discover before any MeshCore link opens a port.
      Isthmus.Networks.MeshCore.Discover,
      {Registry, keys: :unique, name: Isthmus.Networks.MeshCore.Registry},
      Isthmus.Networks.MeshCore.BLESidecar,
      Isthmus.Networks.MeshCore.Companion,
      Isthmus.Networks.MeshCore.Supervisor,
      Isthmus.Networks.MeshCore.BridgeCLI,
      Isthmus.Networks.MeshCore.BridgeLink,
      Isthmus.Networks.MeshCore.SyntheticNode,
      {Registry, keys: :unique, name: Isthmus.Networks.Meshtastic.Registry},
      Isthmus.Networks.Meshtastic.Companion,
      Isthmus.Networks.Meshtastic.Supervisor,
      Isthmus.Networks.Meshtastic.Transport,
      Isthmus.Networks.Reticulum.Sidecar,
      Isthmus.Networks.Nostr.RelayPool,
      Isthmus.Networks.Nostr.ServiceInbox,
      Isthmus.Networks.Agent.Bridge,
      Isthmus.Gateway.Translator
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
