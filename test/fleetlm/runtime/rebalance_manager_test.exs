defmodule Fleetlm.Runtime.RebalanceManagerTest do
  use Fleetlm.StorageCase, async: false

  alias Fleetlm.Runtime.{RebalanceManager, SessionTracker, SessionServer, HashRing}

  setup do
    # Reset hash ring to single node state
    HashRing.refresh!()

    session1 = create_test_session("alice", "bot")
    session2 = create_test_session("bob", "bot")
    session3 = create_test_session("charlie", "bot")

    %{session1: session1, session2: session2, session3: session3}
  end

  describe "rebalance on topology change" do
    test "does nothing when sessions are already on correct node", %{
      session1: session1,
      session2: session2
    } do
      # Start sessions on this node
      {:ok, pid1} = SessionServer.start_link(session1.id)
      {:ok, pid2} = SessionServer.start_link(session2.id)

      # Verify they're running
      node = Node.self()
      assert {:ok, ^node, :running} = SessionTracker.find_session(session1.id)
      node = Node.self()
      assert {:ok, ^node, :running} = SessionTracker.find_session(session2.id)

      # Trigger rebalance with same topology (no changes)
      HashRing.refresh!()
      send(RebalanceManager, :rebalance)

      # Give manager time to process
      Process.sleep(100)

      # Sessions should still be :running (no drain triggered)
      node = Node.self()
      assert {:ok, ^node, :running} = SessionTracker.find_session(session1.id)
      node = Node.self()
      assert {:ok, ^node, :running} = SessionTracker.find_session(session2.id)

      # Cleanup
      GenServer.stop(pid1, :normal)
      GenServer.stop(pid2, :normal)
      Process.sleep(50)
    end

    test "detects when no sessions need rebalancing", %{session1: session1} do
      # Single session on correct node
      {:ok, pid} = SessionServer.start_link(session1.id)

      # Trigger rebalance
      send(RebalanceManager, :rebalance)
      Process.sleep(100)

      # Should still be running
      node = Node.self()
      assert {:ok, ^node, :running} = SessionTracker.find_session(session1.id)

      # Cleanup
      GenServer.stop(pid, :normal)
      Process.sleep(50)
    end

    test "responds to multiple rebalance events", %{session1: session1} do
      {:ok, pid} = SessionServer.start_link(session1.id)

      # Multiple rebalances shouldn't cause issues
      send(RebalanceManager, :rebalance)
      send(RebalanceManager, :rebalance)
      send(RebalanceManager, :rebalance)

      Process.sleep(200)

      # Session should still be healthy
      node = Node.self()
      assert {:ok, ^node, :running} = SessionTracker.find_session(session1.id)

      # Cleanup
      GenServer.stop(pid, :normal)
      Process.sleep(50)
    end
  end

  describe "session ownership tracking" do
    test "handles sessions across their lifecycle", %{
      session1: session1,
      session2: session2,
      session3: session3
    } do
      # Start all sessions
      {:ok, pid1} = SessionServer.start_link(session1.id)
      {:ok, pid2} = SessionServer.start_link(session2.id)
      {:ok, pid3} = SessionServer.start_link(session3.id)

      # All should be tracked as running
      node = Node.self()
      assert {:ok, ^node, :running} = SessionTracker.find_session(session1.id)
      node = Node.self()
      assert {:ok, ^node, :running} = SessionTracker.find_session(session2.id)
      node = Node.self()
      assert {:ok, ^node, :running} = SessionTracker.find_session(session3.id)

      # Verify they're in the registry
      assert [{^pid1, _}] = Registry.lookup(Fleetlm.Runtime.SessionRegistry, session1.id)
      assert [{^pid2, _}] = Registry.lookup(Fleetlm.Runtime.SessionRegistry, session2.id)
      assert [{^pid3, _}] = Registry.lookup(Fleetlm.Runtime.SessionRegistry, session3.id)

      # Trigger rebalance (shouldn't affect anything in single-node)
      send(RebalanceManager, :rebalance)
      Process.sleep(100)

      # All should still be running
      node = Node.self()
      assert {:ok, ^node, :running} = SessionTracker.find_session(session1.id)
      node = Node.self()
      assert {:ok, ^node, :running} = SessionTracker.find_session(session2.id)
      node = Node.self()
      assert {:ok, ^node, :running} = SessionTracker.find_session(session3.id)

      # Cleanup
      GenServer.stop(pid1, :normal)
      GenServer.stop(pid2, :normal)
      GenServer.stop(pid3, :normal)
      Process.sleep(50)
    end

    test "rebalance manager checks HashRing for each session", %{session1: session1} do
      {:ok, pid} = SessionServer.start_link(session1.id)

      # Get the slot for this session
      slot = HashRing.slot_for_session(session1.id)
      owner = HashRing.owner_node(slot)

      # Should be this node
      assert owner == Node.self()

      # Trigger rebalance
      send(RebalanceManager, :rebalance)
      Process.sleep(100)

      # Session should remain running since owner is correct
      node = Node.self()
      assert {:ok, ^node, :running} = SessionTracker.find_session(session1.id)

      # Cleanup
      GenServer.stop(pid, :normal)
      Process.sleep(50)
    end
  end

  describe "edge cases" do
    test "handles rebalance with no active sessions" do
      # No sessions running
      send(RebalanceManager, :rebalance)
      Process.sleep(100)

      # Should complete without error
      :ok
    end

    test "handles concurrent session starts during rebalance", %{
      session1: session1,
      session2: session2
    } do
      # Start first session
      {:ok, pid1} = SessionServer.start_link(session1.id)

      # Trigger rebalance
      send(RebalanceManager, :rebalance)

      # Start second session while rebalancing
      {:ok, pid2} = SessionServer.start_link(session2.id)

      Process.sleep(200)

      # Both should be tracked
      node = Node.self()
      assert {:ok, ^node, :running} = SessionTracker.find_session(session1.id)
      node = Node.self()
      assert {:ok, ^node, :running} = SessionTracker.find_session(session2.id)

      # Cleanup
      GenServer.stop(pid1, :normal)
      GenServer.stop(pid2, :normal)
      Process.sleep(50)
    end
  end
end
