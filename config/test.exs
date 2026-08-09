import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :isthmus, Isthmus.Repo,
  database: Path.expand("../isthmus_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox,
  busy_timeout: 5_000

config :isthmus, vault_secret: "test-vault-secret-not-for-production!!"
config :isthmus, rns_sync_on_boot: false

# Do not open real USB serial ports during the test suite.
config :isthmus, Isthmus.Networks.MeshCore.Discover,
  probe: fn _path, _meta -> :unknown end,
  enumerate: fn -> %{} end,
  env: fn _key -> nil end

# App SyntheticNode must not poll the sandbox DB between tests.
config :isthmus, Isthmus.Networks.MeshCore.SyntheticNode, autoload: false

# Tunnel keepalive pings must not poll the sandbox DB / carriers between tests.
config :isthmus, tunnel_ping_enabled: false

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :isthmus, IsthmusWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "ACxpO8vfJR871CIO2GYDP6LYWMInUhNOV6hAvSEvgXNz1T1EK2nPDryFLh++FY6B",
  server: false

# In test we don't send emails
config :isthmus, Isthmus.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
