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
      Isthmus.Networks.MeshCore.Companion,
      Isthmus.Networks.Meshtastic.Transport,
      Isthmus.Networks.Reticulum.Sidecar,
      Isthmus.Networks.Nostr.RelayPool,
      Isthmus.Gateway.Translator
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
