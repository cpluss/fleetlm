defmodule Fleetlm.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Attach telemetry handlers
    Fleetlm.Telemetry.attach_handlers()

    children = [
      FleetlmWeb.Telemetry,
      Fleetlm.Repo,
      Fleetlm.Cache,
      # Circuit breakers for reliability
      Supervisor.child_spec(
        {Fleetlm.CircuitBreaker,
         name: :db_circuit_breaker, failure_threshold: 5, recovery_time: 30_000},
        id: :db_circuit_breaker
      ),
      Supervisor.child_spec(
        {Fleetlm.CircuitBreaker,
         name: :cache_circuit_breaker, failure_threshold: 3, recovery_time: 10_000},
        id: :cache_circuit_breaker
      ),
      Fleetlm.Chat.Supervisor,
      {DNSCluster, query: Application.get_env(:fleetlm, :dns_cluster_query) || :ignore},
      pubsub_spec(),
      # Start a worker by calling: Fleetlm.Worker.start_link(arg)
      # {Fleetlm.Worker, arg},
      # Start to serve requests, typically the last entry
      FleetlmWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Fleetlm.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    FleetlmWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp pubsub_spec do
    case Application.get_env(:fleetlm, :pubsub_adapter, :local) do
      :redis ->
        {Phoenix.PubSub,
         name: Fleetlm.PubSub,
         adapter: Phoenix.PubSub.Redis,
         host: System.get_env("REDIS_HOST", "localhost"),
         port: String.to_integer(System.get_env("REDIS_PORT", "6379")),
         node_name: System.get_env("NODE_NAME") || "fleetlm_#{:rand.uniform(1000)}"}

      _ ->
        {Phoenix.PubSub, name: Fleetlm.PubSub}
    end
  end
end
