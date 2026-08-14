import Config

# Dev/local: load `.env` so Mix tasks and `mix phx.server` share the same vault
# secret. Without this, ISTHMUS_VAULT_SECRET drifts and proxy keys decrypt-fail.
if config_env() in [:dev, :prod] do
  env_path = Path.expand("../.env", __DIR__)

  if File.exists?(env_path) do
    env_path
    |> File.stream!()
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.each(fn line ->
      case String.split(line, "=", parts: 2) do
        [key, value] ->
          key = String.trim(key)

          value =
            value
            |> String.trim()
            |> String.trim("'")
            |> String.trim("\"")

          if System.get_env(key) in [nil, ""] and key != "" do
            System.put_env(key, value)
          end

        _ ->
          :ok
      end
    end)
  end
end

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.

if System.get_env("PHX_SERVER") do
  config :isthmus, IsthmusWeb.Endpoint, server: true
end

config :isthmus, IsthmusWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

if config_env() == :dev do
  config :isthmus, IsthmusWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        ~r"priv/gettext/.*\.po$"E,
        ~r"lib/isthmus_web/router\.ex$"E,
        ~r"lib/isthmus_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

# Shared across envs when set (dev can override via config/*.exs).
if vault = System.get_env("ISTHMUS_VAULT_SECRET") do
  config :isthmus, vault_secret: vault
end

if config_env() != :test do
  acp_opts = []

  acp_opts =
    case System.get_env("ISTHMUS_ACP_ENABLED") do
      val when val in ["0", "false", "FALSE"] -> Keyword.put(acp_opts, :enabled, false)
      _ -> acp_opts
    end

  acp_opts =
    case System.get_env("ISTHMUS_ACP_COMMAND") do
      nil -> acp_opts
      "" -> Keyword.merge(acp_opts, enabled: false, command: [])
      cmd -> Keyword.put(acp_opts, :command, String.split(cmd))
    end

  acp_opts =
    case System.get_env("ISTHMUS_ACP_CWD") do
      cwd when is_binary(cwd) and cwd != "" -> Keyword.put(acp_opts, :cwd, cwd)
      _ -> acp_opts
    end

  if acp_opts != [] do
    config :isthmus, Isthmus.Networks.Agent, acp_opts
  end
end

mcp_opts = []

mcp_opts =
  case System.get_env("ISTHMUS_MCP_ENABLED") do
    val when val in ["0", "false", "FALSE"] -> Keyword.put(mcp_opts, :enabled, false)
    val when val in ["1", "true", "TRUE"] -> Keyword.put(mcp_opts, :enabled, true)
    _ -> mcp_opts
  end

mcp_opts =
  case System.get_env("ISTHMUS_MCP_TOKEN") do
    nil -> mcp_opts
    "" -> mcp_opts
    token -> Keyword.put(mcp_opts, :token, token)
  end

if mcp_opts != [] do
  config :isthmus, Isthmus.MCP, mcp_opts
end

if config_env() == :prod do
  database_path =
    System.get_env("DATABASE_PATH") ||
      raise """
      environment variable DATABASE_PATH is missing.
      For Docker/Render with a persistent volume, e.g. /data/isthmus.db
      """

  database_path
  |> Path.dirname()
  |> File.mkdir_p!()

  config :isthmus, Isthmus.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      Generate one with: mix phx.gen.secret
      """

  vault_secret =
    System.get_env("ISTHMUS_VAULT_SECRET") ||
      raise """
      environment variable ISTHMUS_VAULT_SECRET is missing.
      Generate one with: openssl rand -base64 48
      """

  host =
    System.get_env("PHX_HOST") ||
      System.get_env("RENDER_EXTERNAL_HOSTNAME") ||
      raise """
      environment variable PHX_HOST is missing.
      For Render, set PHX_HOST to your service hostname (e.g. isthmus.onrender.com)
      or rely on RENDER_EXTERNAL_HOSTNAME.
      """

  port = String.to_integer(System.get_env("PORT") || "4000")

  check_origin =
    case System.get_env("CHECK_ORIGIN") do
      nil ->
        [
          "https://#{host}",
          "http://#{host}",
          "https://#{host}:#{port}",
          "http://#{host}:#{port}"
        ]

      "false" ->
        false

      origins ->
        origins |> String.split(",", trim: true)
    end

  config :isthmus, vault_secret: vault_secret
  config :isthmus, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")
  config :isthmus, :metrics_public, false

  config :isthmus, :metrics_token, System.get_env("ISTHMUS_METRICS_TOKEN")

  # :force_ssl is compile-time (config/prod.exs). Do not set it here.
  # FORCE_SSL=false only adjusts generated URLs for plain-HTTP Docker.
  force_ssl? = System.get_env("FORCE_SSL", "true") != "false"

  url =
    if force_ssl? do
      [host: host, port: 443, scheme: "https"]
    else
      [host: host, port: port, scheme: "http"]
    end

  config :isthmus, IsthmusWeb.Endpoint,
    url: url,
    http: [
      # Bind all interfaces (IPv6 dual-stack) for containers / Render.
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base,
    check_origin: check_origin
end
