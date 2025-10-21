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
        # PubSub (must start before Runtime.Supervisor for SessionTracker)
        pubsub_spec(),
        dns_cluster_spec(),
        # Storage infrastructure (agent cache, HTTP pool)
        Fleetlm.Storage.Supervisor,
        # Runtime infrastructure (Raft, webhooks, inboxes)
        Fleetlm.Runtime.Supervisor
      ]
      |> Enum.concat(cluster_children(topologies))
      |> Enum.reject(&is_nil/1)
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

  defp dns_cluster_spec do
    query = Application.get_env(:fleetlm, :dns_cluster_query) || :ignore

    if Code.ensure_loaded?(DNSCluster) and query != :ignore do
      {DNSCluster, query: query}
    else
      nil
    end
  end
end
