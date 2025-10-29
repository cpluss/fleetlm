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
        # Ecto Repo for archive storage (only if archiving is enabled)
        repo_spec(),
        # PubSub before runtime
        pubsub_spec(),
        # DNS / clustering
        dns_cluster_spec(),
        # Runtime (Raft etc.)
        Fastpaca.Runtime.Supervisor
      ]
      |> Enum.concat(cluster_children(topologies))
      |> Enum.reject(&is_nil/1)
      |> Enum.concat([
        # Endpoint last
        FastpacaWeb.Endpoint
      ])

    opts = [strategy: :one_for_one, name: Fastpaca.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp repo_spec do
    if archive_enabled?() do
      Fastpaca.Repo
    else
      nil
    end
  end

  defp archive_enabled? do
    from_env =
      case System.get_env("FASTPACA_ARCHIVER_ENABLED") do
        nil -> false
        val -> val not in ["", "false", "0", "no", "off"]
      end

    Application.get_env(:fastpaca, :archive_enabled, false) || from_env
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
