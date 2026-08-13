defmodule IsthmusWeb.AdminNav do
  @moduledoc "Shared admin page header and NETWORKS / OPS navigation."
  use Phoenix.Component

  use Phoenix.VerifiedRoutes,
    endpoint: IsthmusWeb.Endpoint,
    router: IsthmusWeb.Router,
    statics: IsthmusWeb.static_paths()

  attr :current, :atom, required: true
  attr :title, :string, required: true
  slot :inner_block

  def admin_header(assigns) do
    ~H"""
    <header class="space-y-5">
      <.admin_nav current={@current} />
      <div>
        <h1 class="text-3xl font-semibold">{@title}</h1>
        <p :if={@inner_block != []} class="mt-1 text-sm text-base-content/70 max-w-2xl">
          {render_slot(@inner_block)}
        </p>
      </div>
    </header>
    """
  end

  attr :current, :atom, default: nil

  def admin_nav(assigns) do
    ~H"""
    <nav
      class="rounded-box border border-base-300 bg-base-200/60 divide-y divide-base-300"
      id="admin-nav"
    >
      <div class="flex items-start gap-3 px-3 py-2" id="admin-nav-networks">
        <span class="mt-1.5 w-20 shrink-0 text-[0.65rem] font-semibold uppercase tracking-widest text-base-content/45">
          Networks
        </span>
        <div class="flex min-w-0 flex-1 flex-wrap gap-1">
          <.nav_link href={~p"/admin/reticulum"} label="Reticulum" current={@current == :reticulum} />
          <.nav_link href={~p"/admin/meshcore"} label="MeshCore" current={@current == :meshcore} />
          <.nav_link
            href={~p"/admin/meshtastic"}
            label="Meshtastic"
            current={@current == :meshtastic}
          />
          <.nav_link href={~p"/admin/nostr"} label="Nostr" current={@current == :nostr} />
        </div>
      </div>
      <div class="flex items-start gap-3 px-3 py-2" id="admin-nav-ops">
        <span class="mt-1.5 w-20 shrink-0 text-[0.65rem] font-semibold uppercase tracking-widest text-base-content/45">
          Ops
        </span>
        <div class="flex min-w-0 flex-1 flex-wrap gap-1">
          <.nav_link href={~p"/admin"} label="Home" current={@current == :home} />
          <.nav_link href={~p"/admin/registrations"} label="Groups" current={@current == :groups} />
          <.nav_link href={~p"/admin/adverts"} label="Adverts" current={@current == :adverts} />
          <.nav_link href={~p"/admin/topology"} label="Topology" current={@current == :topology} />
          <.nav_link href={~p"/admin/gateway"} label="Gateway" current={@current == :gateway} />
          <.nav_link href={~p"/admin/timeline"} label="Timeline" current={@current == :timeline} />
          <.nav_link href={~p"/admin/tunnels"} label="Tunnels" current={@current == :tunnels} />
          <.nav_link href={~p"/admin/audit"} label="Audit" current={@current == :audit} />
          <.nav_link href={~p"/admin/policy"} label="Policy" current={@current == :policy} />
        </div>
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
        "btn btn-sm whitespace-nowrap transition-colors",
        @current && "btn-primary",
        not @current && "btn-ghost"
      ]}
    >
      {@label}
    </.link>
    """
  end
end
