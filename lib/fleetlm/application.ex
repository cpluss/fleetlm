defmodule Fleetlm.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      FleetlmWeb.Telemetry,
      Fleetlm.Repo,
      {Registry, keys: :unique, name: Fleetlm.Chat.ThreadRegistry},
      Fleetlm.Chat.ThreadSupervisor,
      {DNSCluster, query: Application.get_env(:fleetlm, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Fleetlm.PubSub},
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
end
