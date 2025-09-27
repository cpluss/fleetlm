defmodule Fleetlm.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    topologies = Application.get_env(:libcluster, :topologies, [])

    children =
      [
        # Observability stack (PromEx + telemetry helpers)
        Fleetlm.Observability,
        Fleetlm.Repo,
        Fleetlm.Sessions.Supervisor,
        {Task.Supervisor, name: Fleetlm.Agents.DispatcherSupervisor},
        # Agent endpoint status cache for hot path optimization
        Fleetlm.Agents.EndpointCache,
        # Pooled webhook delivery system
        webhook_manager_spec(),
        {DNSCluster, query: Application.get_env(:fleetlm, :dns_cluster_query) || :ignore},
        pubsub_spec()
      ]
      |> Enum.concat(cluster_children(topologies))
      |> Enum.concat([
        # Start to serve requests, typically the last entry
        FleetlmWeb.Endpoint
      ])

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

  defp webhook_manager_spec do
    # Only start webhook manager if poolboy is available
    if Code.ensure_loaded?(:poolboy) do
      pool_size = Application.get_env(:fleetlm, :webhook_pool_size, 10)
      {Fleetlm.Agents.WebhookManager, pool_size: pool_size}
    else
      # Return a no-op spec if poolboy is not available
      Supervisor.child_spec({Task, fn -> :ok end}, id: :webhook_manager_noop, restart: :temporary)
    end
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

  defp cluster_children([]), do: []

  defp cluster_children(topologies) do
    [
      {Cluster.Supervisor, [topologies, [name: Fleetlm.ClusterSupervisor]]}
    ]
  end
end
