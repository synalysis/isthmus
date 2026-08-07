defmodule IsthmusWeb.HomeLive do
  use IsthmusWeb, :live_view

  on_mount {IsthmusWeb.UserAuth, :mount_current_user}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "Isthmus")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <section class="space-y-8">
        <div class="space-y-3">
          <p class="text-sm uppercase tracking-[0.2em] text-base-content/60">
            Multi-network mesh gateway
          </p>
          <h1 class="text-4xl font-semibold tracking-tight">Isthmus</h1>
          <p class="text-lg text-base-content/80 max-w-2xl">
            Connect Reticulum, MeshCore, and Nostr islands. Register an identity,
            mint proxies across networks, and keep announces under control.
          </p>
        </div>

        <div class="flex flex-wrap gap-3">
          <%= if @current_user do %>
            <.link navigate={~p"/me"} class="btn btn-primary">My identities</.link>
            <.link navigate={~p"/register"} class="btn btn-outline">Register</.link>
            <%= if @current_user.admin? do %>
              <.link navigate={~p"/admin"} class="btn btn-secondary">Admin</.link>
            <% end %>
          <% else %>
            <.link navigate={~p"/login"} class="btn btn-primary">Sign in with Nostr</.link>
          <% end %>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
