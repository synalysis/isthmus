defmodule IsthmusWeb.AdminNav do
  @moduledoc "Shared admin navigation clusters."
  use Phoenix.Component

  use Phoenix.VerifiedRoutes,
    endpoint: IsthmusWeb.Endpoint,
    router: IsthmusWeb.Router,
    statics: IsthmusWeb.static_paths()

  attr :current, :atom, default: nil

  def admin_nav(assigns) do
    ~H"""
    <nav class="flex flex-col gap-2 w-full sm:w-auto" id="admin-nav">
      <div class="flex flex-wrap items-center gap-2">
        <span class="text-xs uppercase tracking-wide opacity-50 mr-1">Networks</span>
        <.nav_link href={~p"/admin/reticulum"} label="Reticulum" current={@current == :reticulum} />
        <.nav_link href={~p"/admin/meshcore"} label="MeshCore" current={@current == :meshcore} />
        <.nav_link href={~p"/admin/nostr"} label="Nostr" current={@current == :nostr} />
      </div>
      <div class="flex flex-wrap items-center gap-2">
        <span class="text-xs uppercase tracking-wide opacity-50 mr-1">Ops</span>
        <.nav_link href={~p"/admin/registrations"} label="Groups" current={@current == :groups} />
        <.nav_link href={~p"/admin/adverts"} label="Adverts" current={@current == :adverts} />
        <.nav_link href={~p"/admin/topology"} label="Topology" current={@current == :topology} />
        <.nav_link href={~p"/admin/gateway"} label="Gateway" current={@current == :gateway} />
        <.nav_link href={~p"/admin/timeline"} label="Timeline" current={@current == :timeline} />
        <.nav_link href={~p"/admin/tunnels"} label="Tunnels" current={@current == :tunnels} />
        <.nav_link href={~p"/admin/audit"} label="Audit" current={@current == :audit} />
        <.nav_link href={~p"/admin/policy"} label="Policy" current={@current == :policy} />
        <.nav_link href={~p"/admin"} label="Home" current={@current == :home} />
      </div>
    </nav>
    """
  end

  attr :href, :any, required: true
  attr :label, :string, required: true
  attr :current, :boolean, default: false

  defp nav_link(assigns) do
    ~H"""
    <.link
      navigate={@href}
      class={[
        "btn btn-sm",
        @current && "btn-primary",
        not @current && "btn-outline"
      ]}
    >
      {@label}
    </.link>
    """
  end
end
