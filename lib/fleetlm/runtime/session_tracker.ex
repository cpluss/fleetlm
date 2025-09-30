defmodule Fleetlm.Runtime.SessionTracker do
  @moduledoc """
  Distributed session tracking using Phoenix.Tracker (CRDT-based).

  ## Purpose

  Maintains a cluster-wide eventually-consistent map of which node is running
  which SessionServer, and what status it's in (:running or :draining).

  This solves the distributed consensus problem during cluster topology changes
  (scale-up, scale-down, node failures, rolling deploys).

  ## Architecture

  ### Session Lifecycle States

  ```
  ┌──────────┐    ownership moved    ┌───────────┐    drain complete    ┌─────────┐
  │ :running │ ──────────────────> │ :draining │ ──────────────────> │ removed │
  └──────────┘                      └───────────┘                      └─────────┘
       │                                  │
       │ handle requests                  │ reject with :draining (backpressure)
       ▼                                  ▼
  ```

  ### Why This Design Works

  **Problem:** When cluster topology changes (e.g. scale from 3 to 4 nodes),
  the HashRing redistributes session ownership. Some sessions need to move
  from their current node to a new owner node.

  **Naive approach fails:** Simply draining on the old node and starting on
  the new node creates a race condition window where:
  - Old node hasn't finished draining yet
  - New node thinks it should own the session
  - Both nodes try to run the same SessionServer
  - Split brain! Two processes writing to the same session!

  **Our solution:** Use Phoenix.Tracker as a global "where is session X" map
  with a :draining status that provides atomic transition semantics:

  1. **Initial state:** session_x tracked as `{node: node2, status: :running}`
  2. **Topology change detected:** RebalanceManager determines session_x should move to node4
  3. **Mark as draining:** Update tracker to `{node: node2, status: :draining}`
     - Session STILL on node2 (not removed from tracker yet)
     - But status signals "I'm draining, don't route to me"
  4. **Router sees :draining:** Rejects requests with {:error, :draining}
     - Provides natural backpressure to channels
     - Client can retry after brief delay
  5. **Drain completes:** SessionServer terminates on node2
     - Phoenix.Tracker automatically removes entry on process death
     - NOW session_x is removed from tracker
  6. **Next request:** Tracker returns :not_found
     - Router consults HashRing: "session_x should be on node4"
     - Routes to node4, starts fresh SessionServer
     - Tracked as `{node: node4, status: :running}`

  ### Safety Guarantees

  - **No split brain:** Only one tracker entry at a time (atomic :running → :draining → removed)
  - **Natural backpressure:** :draining status propagates to client as retry signal
  - **Crash recovery:** Process death auto-removes from tracker, next request starts fresh
  - **Eventually consistent:** CRDTs handle network partitions gracefully
  - **Sticky routing:** While :running, requests route to current location (ignores HashRing)

  ### Cluster Topology Change Flow

  Example: Scale from 3 to 4 nodes

  ```
  t=0: session_x running on node2
       Tracker: session_x → {node: node2, status: :running}

  t=1: node4 joins cluster
       Phoenix.Tracker broadcasts node4 presence via CRDT gossip

  t=2: All nodes receive handle_diff/2 callback
       Each node: HashRing.refresh!() with [node1, node2, node3, node4]

  t=3: node2's RebalanceManager checks local sessions:
       - session_x slot now owned by node4 (per HashRing)
       - Ownership moved! Call SessionTracker.mark_draining(session_x)
       - Tracker: session_x → {node: node2, status: :draining}  ← STILL on node2!
       - Trigger SessionServer.drain(session_x) asynchronously

  t=4: Request arrives at gateway node1:
       - Router calls SessionTracker.find_session(session_x)
       - Returns: {:ok, node2, :draining}
       - Router forwards to node2
       - node2 SessionServer: {:error, :draining}
       - Channel pushes "backpressure" event, retry_after_ms: 1000

  t=5: node2 completes drain:
       - Flushes disk log to DB
       - SessionServer terminates
       - Tracker automatically removes session_x  ← NOW gone!

  t=6: Client retries request:
       - Router calls SessionTracker.find_session(session_x)
       - Returns: :not_found
       - Router consults HashRing: session_x → node4
       - Forward to node4
       - node4 starts SessionServer, registers with tracker
       - Tracker: session_x → {node: node4, status: :running}  ← NEW location!
  ```

  ### Key Implementation Details

  - Phoenix.Tracker automatically removes entries when tracked process dies
  - CRDTs ensure eventual consistency across cluster
  - handle_diff/2 callback detects topology changes (node joins/leaves)
  - RebalanceManager is triggered to check which sessions need to move
  - Drain is async (non-blocking) - requests are rejected during drain window
  """

  use Phoenix.Tracker

  @doc """
  Start the tracker linked to the current process.
  """
  def start_link(opts) do
    opts = Keyword.merge([name: __MODULE__], opts)
    Phoenix.Tracker.start_link(__MODULE__, opts, opts)
  end

  @doc """
  Required callback for Phoenix.Tracker.
  """
  def init(opts) do
    server = Keyword.fetch!(opts, :pubsub_server)
    {:ok, %{pubsub_server: server, node_name: Phoenix.PubSub.node_name(server)}}
  end

  @doc """
  Track a session as running on this node.

  Called by SessionServer.init/1 when a session starts.

  ## Parameters
  - pid: The SessionServer process pid
  - session_id: The session identifier
  - metadata: Map with :node and :status keys

  ## Example

      SessionTracker.track(self(), "session-123", %{
        node: Node.self(),
        status: :running
      })
  """
  def track(pid, session_id, metadata) do
    Phoenix.Tracker.track(__MODULE__, pid, "sessions", session_id, metadata)
  end

  @doc """
  Update a session's status to :draining without untracking it.

  Called by RebalanceManager when ownership moves to another node.

  ## Example

      SessionTracker.mark_draining("session-123")
  """
  def mark_draining(session_id) do
    # Look up the SessionServer PID from the registry
    case Registry.lookup(Fleetlm.Runtime.SessionRegistry, session_id) do
      [{pid, _}] ->
        Phoenix.Tracker.update(__MODULE__, pid, "sessions", session_id, %{
          node: Node.self(),
          status: :draining
        })

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Find where a session is currently running.

  ## Returns
  - `{:ok, node, :running}` - Session is running on node and accepting requests
  - `{:ok, node, :draining}` - Session is draining on node, reject requests
  - `:not_found` - Session not tracked anywhere (safe to start)

  ## Example

      case SessionTracker.find_session("session-123") do
        {:ok, node, :running} -> route_to(node)
        {:ok, node, :draining} -> {:error, :draining}
        :not_found -> start_on_owner_node()
      end
  """
  def find_session(session_id) do
    case Phoenix.Tracker.list(__MODULE__, "sessions")
         |> Enum.find(fn {id, _meta} -> id == session_id end) do
      nil ->
        :not_found

      {_id, %{node: node, status: status}} ->
        {:ok, node, status}
    end
  end

  @doc """
  Called when cluster topology changes (nodes join/leave).

  This callback receives diffs from the CRDT gossip protocol and triggers
  rebalancing when nodes are added or removed.

  The diff format is: %{"sessions" => {joins, leaves}} where joins and leaves
  are lists of {session_id, metadata} tuples.
  """
  def handle_diff(_diff, state) do
    # Diff format: %{"sessions" => {joins_list, leaves_list}}
    # We don't need to process individual session joins/leaves here.
    # We only care about node-level topology changes which happen via
    # Phoenix.Tracker's internal gossip when a node joins/leaves the cluster.
    #
    # For now, we'll trigger rebalancing on ANY diff, but in production
    # you might want to be smarter about detecting actual node changes vs
    # just session churn.

    # TODO: Detect actual node topology changes vs session churn
    # For now: always check (safe but potentially wasteful)
    send(Fleetlm.Runtime.RebalanceManager, :rebalance)

    {:ok, state}
  end
end
