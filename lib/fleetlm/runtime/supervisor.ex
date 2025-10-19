defmodule Fleetlm.Runtime.Supervisor do
  @moduledoc """
  Root supervisor for the Raft-based runtime tree.

  Starts:
  - RaftManager (256 Raft groups for distributed message storage)
  - Flusher (write-behind to Postgres every 5s)
  - InboxSupervisor (user inbox processes - unchanged)
  - DrainCoordinator (graceful SIGTERM handling)

  ## What Changed from WAL Architecture

  DELETED:
  - Storage.Supervisor (SlotLogServers) → Replaced by Ra WAL (RAM)
  - SessionRegistry / SessionSupervisor → No more per-session processes
  - SessionTracker (CRDT) → Raft membership handles routing
  - RebalanceManager → Leadership transfer handles rebalancing

  NEW:
  - RaftManager → Manages 256 Raft groups
  - Flusher → Background write-behind to Postgres
  """

  use Supervisor

  alias Fleetlm.Runtime.InboxSupervisor

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Raft group manager (starts 256 Raft groups)
      Fleetlm.Runtime.RaftManager,

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
