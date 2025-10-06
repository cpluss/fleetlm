# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :fleetlm,
  ecto_repos: [Fleetlm.Repo],
  generators: [timestamp_type: :utc_datetime]

config :fleetlm, Fleetlm.Runtime.Sharding.HashRing,
  slot_count: 512,
  virtual_nodes_per_node: 128

config :fleetlm, Fleetlm.Runtime.DrainCoordinator,
  drain_timeout: :timer.seconds(30),
  drain_grace_period: :timer.seconds(2)

# Configures the endpoint
config :fleetlm, FleetlmWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: FleetlmWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Fleetlm.PubSub

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :libcluster, topologies: []

config :fleetlm, Fleetlm.Observability.PromEx,
  metrics_server: :disabled,
  grafana_agent: :disabled

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
