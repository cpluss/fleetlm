defmodule Fleetlm.Runtime.RebalanceManager do
  @moduledoc """
  Coordinates session rebalancing when cluster topology changes.

  ## Responsibilities

  - Listen for topology change notifications from SessionTracker
  - Refresh the HashRing with new cluster membership
  - Compare current session ownership to desired ownership
  - Trigger draining for sessions that need to move to other nodes

  ## Design

  When a node joins or leaves the cluster:

  1. SessionTracker.handle_diff/2 detects the change
  2. Sends `:rebalance` message to this manager
  3. Manager refreshes HashRing with new node list
  4. Iterates through all local sessions:
     - Calculate new owner per HashRing
     - If owner changed → mark as :draining and trigger drain
  5. SessionServer drains gracefully and terminates
  6. Tracker auto-removes session on termination
  7. Next request routes to new owner node

  This process happens independently on each node, checking only its own
  local sessions. No cross-node coordination needed (tracker provides
  eventual consistency).
  """

  use GenServer
  require Logger

  alias Fleetlm.Runtime.{HashRing, SessionTracker, SessionServer}

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Logger.info("RebalanceManager started")
    {:ok, %{}}
  end

  @impl true
  def handle_info(:rebalance, state) do
    Logger.info("Rebalancing sessions due to topology change")

    # Refresh hash ring with new cluster membership
    ring = HashRing.refresh!()

    Logger.info("HashRing refreshed: #{length(ring.nodes)} nodes, generation #{ring.generation}")

    # Check each local session for ownership changes
    moved_count =
      Registry.select(Fleetlm.Runtime.SessionRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])
      |> Enum.reduce(0, fn session_id, acc ->
        slot = HashRing.slot_for_session(session_id)
        new_owner = HashRing.owner_node(slot)

        if new_owner != Node.self() do
          Logger.info("Session #{session_id} ownership moved to #{new_owner}, triggering drain")

          # Mark as draining in tracker (still present, but draining status)
          SessionTracker.mark_draining(session_id)

          # Trigger async drain (non-blocking)
          Task.start(fn ->
            case SessionServer.drain(session_id) do
              :ok ->
                Logger.info("Session #{session_id} drained successfully")

              {:error, reason} ->
                Logger.warning("Session #{session_id} drain failed: #{inspect(reason)}")
            end
          end)

          acc + 1
        else
          # Still owned by us, no action needed
          acc
        end
      end)

    if moved_count > 0 do
      Logger.info("Triggered drain for #{moved_count} sessions")
    else
      Logger.debug("No sessions need rebalancing")
    end

    {:noreply, state}
  end
end
