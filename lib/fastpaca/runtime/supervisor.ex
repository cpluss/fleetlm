defmodule Fastpaca.Runtime.Supervisor do
  @moduledoc """
  Root supervisor for the Raft-based runtime tree.

  ## Boot Order

  1. Task.Supervisor - Async Raft group startup (Horde pattern)
  2. RaftTopology.Presence - CRDT for cluster membership (Phoenix.Presence)
  3. RaftTopology - Coordinates Raft membership changes
  4. Flusher - Write-behind to Postgres every 5s
  5. InboxSupervisor - Per-user inbox processes
  6. DrainCoordinator - Graceful shutdown on SIGTERM

  ## Architecture

  - RaftTopology: Monitors cluster via libcluster + Presence, rebalances Raft groups
  - RaftManager: Pure utility module for placement and group lifecycle
  - 256 Raft groups × 3 replicas = 768 Ra servers across cluster
  - Dynamic membership: nodes join/leave via Ra's add_member/remove_member APIs
  """

  use Supervisor

  alias Fastpaca.Runtime.InboxSupervisor

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    flusher_children =
      if Application.get_env(:fastpaca, :runtime_flusher_enabled, true) do
        [Fastpaca.Runtime.Flusher]
      else
        []
      end

    children =
      [
        # Task.Supervisor for async Raft group startup (Horde pattern)
        {Task.Supervisor, name: Fleetlm.RaftTaskSupervisor},

        # Registry + supervisor for webhook workers
        {Registry, keys: :unique, name: Fleetlm.Webhook.WorkerRegistry},
        Fleetlm.Webhook.WorkerSupervisor,

        # Presence replicates ready-node membership across the cluster
        Fastpaca.Runtime.RaftTopology.Presence,

        # Topology coordinator (monitors cluster, manages Raft membership)
        Fastpaca.Runtime.RaftTopology,

        # Inbox registry and supervisor (unchanged)
        {Registry, keys: :unique, name: Fastpaca.Runtime.InboxRegistry},
        {InboxSupervisor, []},

        # Graceful drain coordinator for SIGTERM handling
        Fastpaca.Runtime.DrainCoordinator
      ] ++ flusher_children

    Supervisor.init(children, strategy: :one_for_one)
  end
end
