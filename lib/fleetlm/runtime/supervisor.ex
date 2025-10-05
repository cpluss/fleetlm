defmodule Fleetlm.Runtime.Supervisor do
  @moduledoc """
  Root supervisor for the session runtime tree.

  Starts storage layer, registries, and dynamic supervisors that manage
  SessionServer/InboxServer processes. Also includes DrainCoordinator
  for graceful SIGTERM handling during deployments.
  """

  use Supervisor

  alias Fleetlm.Runtime.SessionSupervisor
  alias Fleetlm.Runtime.InboxSupervisor

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Storage layer (SlotLogServers with disk logs)
      Fleetlm.Storage.Supervisor,

      # Registries for process lookup
      {Registry, keys: :unique, name: Fleetlm.Runtime.SessionRegistry},
      {Registry, keys: :unique, name: Fleetlm.Runtime.InboxRegistry},

      # Distributed session tracker (Phoenix.Tracker with CRDTs)
      {Fleetlm.Runtime.SessionTracker, [pubsub_server: Fleetlm.PubSub]},

      # Dynamic supervisors for session and inbox servers
      {SessionSupervisor, []},
      {InboxSupervisor, []},

      # Rebalance manager (listens for topology changes from tracker)
      Fleetlm.Runtime.RebalanceManager,

      # Graceful drain coordinator for SIGTERM handling
      Fleetlm.Runtime.DrainCoordinator
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
