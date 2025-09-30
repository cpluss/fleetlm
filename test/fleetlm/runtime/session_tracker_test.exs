defmodule Fleetlm.Runtime.SessionTrackerTest do
  use Fleetlm.StorageCase, async: false

  alias Fleetlm.Runtime.{SessionTracker, SessionServer}

  setup do
    session = create_test_session("alice", "bot")
    %{session: session}
  end

  describe "track/3" do
    test "tracks a session as :running", %{session: session} do
      # Start a session server (which tracks itself)
      {:ok, pid} = SessionServer.start_link(session.id)

      # Should be tracked as :running
      node = Node.self()
      assert {:ok, ^node, :running} = SessionTracker.find_session(session.id)

      # Cleanup
      ref = Process.monitor(pid)
      GenServer.stop(pid, :normal)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
    end

    test "multiple sessions can be tracked independently", %{session: session1} do
      session2 = create_test_session("bob", "bot")

      {:ok, pid1} = SessionServer.start_link(session1.id)
      {:ok, pid2} = SessionServer.start_link(session2.id)

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

  describe "mark_draining/1" do
    test "updates session status to :draining", %{session: session} do
      # Start session server
      {:ok, pid} = SessionServer.start_link(session.id)
      node = Node.self()
      assert {:ok, ^node, :running} = SessionTracker.find_session(session.id)

      # Mark as draining
      SessionTracker.mark_draining(session.id)

      # Status should be updated
      node = Node.self()
      assert {:ok, ^node, :draining} = SessionTracker.find_session(session.id)

      # Cleanup
      GenServer.stop(pid, :normal)
      Process.sleep(50)
    end

    test "session remains tracked while draining", %{session: session} do
      {:ok, pid} = SessionServer.start_link(session.id)
      SessionTracker.mark_draining(session.id)

      # Still tracked, just with different status
      result = SessionTracker.find_session(session.id)
      assert {:ok, _node, :draining} = result

      # Cleanup
      GenServer.stop(pid, :normal)
      Process.sleep(50)
    end
  end

  describe "find_session/1" do
    test "returns :not_found for non-existent session" do
      assert :not_found = SessionTracker.find_session("non-existent-session-id")
    end

    test "returns session info after tracking", %{session: session} do
      {:ok, pid} = SessionServer.start_link(session.id)

      result = SessionTracker.find_session(session.id)
      assert {:ok, node, :running} = result
      assert node == Node.self()

      # Cleanup
      GenServer.stop(pid, :normal)
      Process.sleep(50)
    end

    test "returns :not_found after session terminates", %{session: session} do
      {:ok, pid} = SessionServer.start_link(session.id)
      assert {:ok, _, :running} = SessionTracker.find_session(session.id)

      # Stop the session
      ref = Process.monitor(pid)
      GenServer.stop(pid, :normal)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000

      # Give tracker time to process the termination
      Process.sleep(100)

      # Should no longer be tracked
      assert :not_found = SessionTracker.find_session(session.id)
    end
  end

  describe "lifecycle" do
    test "session goes through full lifecycle: running -> draining -> removed", %{
      session: session
    } do
      # Start: :running
      {:ok, pid} = SessionServer.start_link(session.id)
      node = Node.self()
      assert {:ok, ^node, :running} = SessionTracker.find_session(session.id)

      # Transition to :draining
      SessionTracker.mark_draining(session.id)
      node = Node.self()
      assert {:ok, ^node, :draining} = SessionTracker.find_session(session.id)

      # Terminate: removed from tracker
      ref = Process.monitor(pid)
      GenServer.stop(pid, :normal)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
      Process.sleep(100)

      assert :not_found = SessionTracker.find_session(session.id)
    end
  end
end
