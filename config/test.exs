import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :fastpaca, Fastpaca.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "fastpaca_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10,
  timeout: 60000,
  ownership_timeout: 120_000

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :fleetlm, FleetlmWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "j00A2bogYM9pz50icwpf23zy58245sY8GUZ67/P1CqXOIxD0kbwNBPR4vjbfl82k",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Use local PubSub for tests to avoid Redis dependency
config :fleetlm, :pubsub_adapter, :local

# Disable agent webhooks by default in tests
config :fleetlm, :disable_agent_webhooks, true

config :fleetlm, :persist_context_snapshots, false

# Eliminate drain grace period in tests to reduce artificial sleeps
config :fleetlm, Fleetlm.Runtime.DrainCoordinator,
  drain_timeout: :timer.seconds(5),
  drain_grace_period: 0

# Raft test configuration
config :fleetlm,
  raft_data_dir: "tmp/test_raft",
  raft_flush_interval_ms: 100,
  runtime_flusher_enabled: false,
  flusher_async: false
