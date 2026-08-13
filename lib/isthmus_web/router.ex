defmodule IsthmusWeb.Router do
  use IsthmusWeb, :router

  import IsthmusWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {IsthmusWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_user
  end

  pipeline :health do
    plug :accepts, ["json", "html", "*/*"]
  end

  pipeline :metrics do
    plug :accepts, ["text", "json", "*/*"]
  end

  pipeline :mcp do
    plug :accepts, ["json"]
    plug IsthmusWeb.Plugs.McpAuth
  end

  scope "/", IsthmusWeb do
    pipe_through :health

    get "/health", HealthController, :liveness
    get "/healthz", HealthController, :liveness
    get "/readyz", HealthController, :readiness
  end

  scope "/", IsthmusWeb do
    pipe_through :metrics

    get "/metrics", MetricsController, :index
  end

  scope "/" do
    pipe_through :mcp

    forward "/mcp", ExMCP.HttpPlug,
      handler: Isthmus.MCP.Server,
      protocol_mode: :prefer_modern,
      server_info: %{name: "isthmus", version: "0.1.0"},
      instructions: Isthmus.MCP.Server.instructions(),
      cors_enabled: true,
      validate_origin: false,
      allowed_origins: :any,
      handler_call_timeout: 30_000
  end

  scope "/", IsthmusWeb do
    pipe_through :browser

    live "/", HomeLive
    live "/login", LoginLive
    get "/session", SessionController, :create
    post "/session", SessionController, :create
    delete "/logout", SessionController, :delete

    live_session :authenticated,
      on_mount: [{IsthmusWeb.UserAuth, :ensure_authenticated}] do
      live "/register", RegisterLive
      live "/me", MeLive
    end

    live_session :admin,
      on_mount: [{IsthmusWeb.UserAuth, :ensure_admin}] do
      live "/admin", Admin.HomeLive
      live "/admin/reticulum", Admin.ReticulumLive
      live "/admin/meshcore", Admin.MeshCoreLive
      live "/admin/meshtastic", Admin.MeshtasticLive
      live "/admin/nostr", Admin.NostrLive
      live "/admin/agent", Admin.AgentLive
      # Legacy bookmark; same LiveView as /admin/nostr
      live "/admin/relays", Admin.NostrLive
      live "/admin/registrations", Admin.RegistrationsLive
      live "/admin/adverts", Admin.AdvertsLive
      live "/admin/topology", Admin.TopologyLive
      live "/admin/tunnels", Admin.TunnelsLive
      live "/admin/gateway", Admin.GatewayLive
      live "/admin/timeline", Admin.TimelineLive
      live "/admin/audit", Admin.AuditLive
      live "/admin/policy", Admin.PolicyLive
    end
  end

  if Application.compile_env(:isthmus, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: IsthmusWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
