import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :fleetlm, Fleetlm.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "fleetlm_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 3,
  timeout: 60000,
  ownership_timeout: 120_000

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :fleetlm, FleetlmWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "j00A2bogYM9pz50icwpf23zy58245sY8GUZ67/P1CqXOIxD0kbwNBPR4vjbfl82k",
  server: false

# In test we don't send emails
config :fleetlm, Fleetlm.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

config :fleetlm, :participant_tick_interval_ms, 100

# Use local PubSub for tests to avoid Redis dependency
config :fleetlm, :pubsub_adapter, :local

config :fleetlm, :persistence_worker_mode, :noop

# Increase slot flush timeout for tests (slower due to sandbox mode)
config :fleetlm, :slot_flush_timeout, 15_000

# Disable agent webhooks by default in tests
config :fleetlm, :disable_agent_webhooks, true

# Skip DB operations in terminate callbacks (avoids ownership errors when test exits)
config :fleetlm, :skip_terminate_db_ops, true

# Faster flush interval for tests (default is 300ms, but we can make it even faster)
config :fleetlm, :storage_flush_interval_ms, 100

# Use test mode for slot logs - SlotLogServers are started on-demand per test
# instead of being globally supervised at application startup
config :fleetlm, :slot_log_mode, :test

# Eliminate drain grace period in tests to reduce artificial sleeps
config :fleetlm, Fleetlm.Runtime.DrainCoordinator, drain_grace_period: 0

# Suppress expected slot flush error logs in negative-path storage tests
config :fleetlm, :suppress_slot_flush_errors, true
