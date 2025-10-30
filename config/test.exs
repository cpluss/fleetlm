import Config

# Configure database for tests
config :fastpaca, Fastpaca.Repo,
  url: "ecto://postgres:postgres@localhost:5432/fastpaca_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :fastpaca, FastpacaWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "j00A2bogYM9pz50icwpf23zy58245sY8GUZ67/P1CqXOIxD0kbwNBPR4vjbfl82k",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Use local PubSub for tests to avoid Redis dependency
config :fastpaca, :pubsub_adapter, :local

# Disable agent webhooks by default in tests
config :fastpaca, :disable_agent_webhooks, true

config :fastpaca, :persist_context_snapshots, false

# Raft test configuration
config :fastpaca,
  raft_data_dir: "tmp/test_raft",
  raft_flush_interval_ms: 100,
  runtime_flusher_enabled: false,
  flusher_async: false
