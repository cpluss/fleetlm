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

  **Naive approach:** Simply draining on the old node and starting on
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
  alias MapSet

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
  @impl true
  def init(opts) do
    server = Keyword.fetch!(opts, :pubsub_server)

    # Monitor node membership changes so we can detect topology updates even
    # when there is no presence churn (e.g. a brand-new node with zero
    # sessions yet).
    :ok = :net_kernel.monitor_nodes(true, [:nodedown_reason])

    state = %{
      pubsub_server: server,
      node_name: Phoenix.PubSub.node_name(server),
      known_nodes: current_nodes_set()
    }

    {:ok, state}
  end

  @doc """
  Track a session as running on this node.
  Called by SessionServer.init/1 when a session starts.
  """
  def track(pid, session_id, metadata) do
    Phoenix.Tracker.track(__MODULE__, pid, "sessions", session_id, metadata)
  end

  @doc """
  Update a session's status to :draining without untracking it.

  Called by RebalanceManager when ownership moves to another node.
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

  We inspect the diff for previously unseen nodes so we can avoid triggering
  rebalancing on routine session churn. Node monitor events complement this so
  we still rebalance when a node joins/leaves before it tracks any sessions.

  The diff format is: %{"sessions" => {joins, leaves}} where joins and leaves
  are lists of {session_id, metadata} tuples.
  """
  @impl true
  def handle_diff(diff, state) do
    {known_nodes, trigger?} = diff_topology_change(diff, state.known_nodes)
    state = %{state | known_nodes: known_nodes}

    if trigger?, do: send(Fleetlm.Runtime.RebalanceManager, :rebalance)

    {:ok, state}
  end

  @impl true
  def handle_info({:nodeup, node}, state), do: handle_nodeup(node, state)

  @impl true
  def handle_info({:nodeup, node, _info}, state), do: handle_nodeup(node, state)

  @impl true
  def handle_info({:nodedown, node}, state), do: handle_nodedown(node, state)

  @impl true
  def handle_info({:nodedown, node, _info}, state), do: handle_nodedown(node, state)

  @impl true
  def handle_info(_message, state), do: {:noreply, state}

  defp handle_nodeup(node, %{known_nodes: known_nodes} = state) do
    cond do
      node == Node.self() ->
        {:noreply, state}

      MapSet.member?(known_nodes, node) ->
        {:noreply, state}

      true ->
        send(Fleetlm.Runtime.RebalanceManager, :rebalance)
        {:noreply, %{state | known_nodes: MapSet.put(known_nodes, node)}}
    end
  end

  defp handle_nodedown(node, %{known_nodes: known_nodes} = state) do
    cond do
      node == Node.self() ->
        {:noreply, state}

      MapSet.member?(known_nodes, node) ->
        send(Fleetlm.Runtime.RebalanceManager, :rebalance)
        {:noreply, %{state | known_nodes: MapSet.delete(known_nodes, node)}}

      true ->
        {:noreply, state}
    end
  end

  @doc false
  def diff_topology_change(diff, known_nodes) do
    new_nodes =
      diff
      |> Map.get("sessions", {[], []})
      |> nodes_from_diff()

    cond do
      MapSet.size(new_nodes) == 0 -> {known_nodes, false}
      MapSet.subset?(new_nodes, known_nodes) -> {known_nodes, false}
      true -> {MapSet.union(known_nodes, new_nodes), true}
    end
  end

  defp nodes_from_diff({joins, leaves}) do
    joins
    |> Enum.concat(leaves)
    |> Enum.reduce(MapSet.new(), fn
      {_key, %{node: node}}, acc when is_atom(node) -> MapSet.put(acc, node)
      _entry, acc -> acc
    end)
  end

  defp nodes_from_diff(_), do: MapSet.new()

  defp current_nodes_set do
    [Node.self() | Node.list()]
    |> Enum.into(MapSet.new())
  end
end
