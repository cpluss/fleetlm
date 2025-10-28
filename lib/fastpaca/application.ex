defmodule Fastpaca.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    topologies = Application.get_env(:libcluster, :topologies, [])

    children =
      [
        # PromEx metrics
        Fastpaca.Observability.PromEx,
        pubsub_spec(),
        Fastpaca.Runtime.Supervisor,
        FastpacaWeb.Endpoint,
        dns_cluster_spec()
      ]
      |> Enum.concat(cluster_children(topologies))
      |> Enum.reject(&is_nil/1)

    opts = [strategy: :one_for_one, name: Fastpaca.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp pubsub_spec do
    case Application.get_env(:fastpaca, :pubsub_adapter, :local) do
      :redis ->
        {Phoenix.PubSub,
         name: Fastpaca.PubSub,
         adapter: Phoenix.PubSub.Redis,
         host: System.get_env("REDIS_HOST", "localhost"),
         port: String.to_integer(System.get_env("REDIS_PORT", "6379")),
         node_name: System.get_env("NODE_NAME") || "fastpaca_#{:rand.uniform(1000)}"}

      _ ->
        {Phoenix.PubSub, name: Fastpaca.PubSub}
    end
  end

  defp cluster_children([]), do: []

  defp cluster_children(topologies) do
    [
      {Cluster.Supervisor, [topologies, [name: Fastpaca.ClusterSupervisor]]}
    ]
  end

  defp dns_cluster_spec do
    query = Application.get_env(:fastpaca, :dns_cluster_query) || :ignore

    if Code.ensure_loaded?(DNSCluster) and query != :ignore do
      {DNSCluster, query: query}
    else
      nil
    end
  end
end
