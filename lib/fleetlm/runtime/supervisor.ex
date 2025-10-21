defmodule Fleetlm.Runtime.Supervisor do
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

  alias Fleetlm.Runtime.InboxSupervisor

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Task.Supervisor for async Raft group startup (Horde pattern)
      {Task.Supervisor, name: Fleetlm.RaftTaskSupervisor},

      # Task.Supervisor for worker jobs (agent webhooks, compaction)
      {Task.Supervisor, name: Fleetlm.Webhook.Manager.TaskSupervisor},

      # Job manager (coordinates workers on leader node)
      Fleetlm.Webhook.Manager,

      # Presence replicates ready-node membership across the cluster
      Fleetlm.Runtime.RaftTopology.Presence,

      # Topology coordinator (monitors cluster, manages Raft membership)
      Fleetlm.Runtime.RaftTopology,

      # Background flusher (write-behind to Postgres)
      Fleetlm.Runtime.Flusher,

      # Inbox registry and supervisor (unchanged)
      {Registry, keys: :unique, name: Fleetlm.Runtime.InboxRegistry},
      {InboxSupervisor, []},

      # Graceful drain coordinator for SIGTERM handling
      Fleetlm.Runtime.DrainCoordinator
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
