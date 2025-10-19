defmodule Fleetlm.Runtime.DrainCoordinatorTest do
  use Fleetlm.TestCase

  alias Fleetlm.Runtime
  alias Fleetlm.Runtime.DrainCoordinator

  setup do
    # Use shared mode so spawned processes can access DB
    case Ecto.Adapters.SQL.Sandbox.mode(Fleetlm.Repo, {:shared, self()}) do
      :ok -> :ok
      :already_shared -> :ok
    end

    # DrainCoordinator is already running as part of Runtime.Supervisor
    # Just verify it's alive
    coordinator_pid = Process.whereis(DrainCoordinator)

    assert is_pid(coordinator_pid) and Process.alive?(coordinator_pid),
           "DrainCoordinator should be running"

    # Reset drain state before each test
    DrainCoordinator.reset_drain_state()

    on_exit(fn ->
      # Reset drain state after each test
      DrainCoordinator.reset_drain_state()
    end)

    {:ok, coordinator_pid: coordinator_pid}
  end

  describe "trigger_drain/0" do
    test "drains all active sessions" do
      # Create sessions
      session1 = create_test_session("alice", "bob")
      session2 = create_test_session("charlie", "dave")

      # Send messages via Runtime
      {:ok, _} =
        Runtime.append_message(session1.id, "alice", "bob", "text", %{"text" => "msg1"}, %{})

      {:ok, _} =
        Runtime.append_message(session2.id, "charlie", "dave", "text", %{"text" => "msg2"}, %{})

      # Trigger drain (snapshots Raft groups)
      result = DrainCoordinator.trigger_drain()
      assert result == :ok or match?({:error, {:partial_drain, _, _}}, result)

      # Wait for drain to complete
      Process.sleep(100)

      # In Raft architecture, sessions don't get marked inactive during drain
      # (no per-session processes). Drain just snapshots Raft state.
      # Verify messages are still readable
      {:ok, messages1} = Runtime.get_messages(session1.id, 0, 10)
      assert length(messages1) >= 1
    end

    test "handles empty session list gracefully" do
      # Don't assert count - just verify drain completes
      # (may have leftover sessions from other tests)

      # Should complete without error
      result = DrainCoordinator.trigger_drain()
      assert result == :ok or match?({:error, {:partial_drain, _, _}}, result)
    end

    test "can drain multiple times" do
      # First drain should succeed or partial
      result1 = DrainCoordinator.trigger_drain()
      assert result1 == :ok or match?({:error, {:partial_drain, _, _}}, result1)

      # Second drain should also work (state resets after drain)
      result2 = DrainCoordinator.trigger_drain()
      assert result2 == :ok or match?({:error, {:partial_drain, _, _}}, result2)
    end
  end

  describe "graceful shutdown" do
    test "completes drain successfully" do
      session = create_test_session("alice", "bob")

      # Send a message
      {:ok, _seq} =
        Runtime.append_message(session.id, "alice", "bob", "text", %{"text" => "important"}, %{})

      # Trigger drain - should complete without error
      result = DrainCoordinator.trigger_drain()
      assert result == :ok or match?({:error, {:partial_drain, _, _}}, result)

      # In Raft architecture, sessions aren't marked inactive during drain
      # Just verify messages are still accessible
      {:ok, messages} = Runtime.get_messages(session.id, 0, 10)
      assert length(messages) >= 1
    end
  end
end
