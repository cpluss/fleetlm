defmodule Fleetlm.Agent.DebouncerTest do
  use Fleetlm.TestCase, async: false

  alias Fleetlm.Agent.Debouncer

  setup do
    agent = create_agent("test-agent", %{debounce_window_ms: 100})
    session = create_test_session("user-123", agent.id)

    %{agent: agent, session: session}
  end

  describe "schedule/5" do
    test "accepts scheduling requests", %{session: session, agent: agent} do
      # Should not crash
      assert :ok = Debouncer.schedule(session.id, agent.id, "user-123", 1, 100)
      assert :ok = Debouncer.schedule(session.id, agent.id, "user-123", 2, 100)
    end

    test "calculates correct batch size via telemetry", %{session: session, agent: agent} do
      # Attach telemetry handler to capture events for THIS session only
      handler_id = "test-debounce-#{:erlang.unique_integer()}"
      test_pid = self()
      session_id = session.id

      :telemetry.attach(
        handler_id,
        [:fleetlm, :agent, :debounce],
        fn _event, measurements, metadata, _config ->
          # Only send to test if it's for our session
          if metadata.session_id == session_id do
            send(test_pid, {:telemetry, :debounce, measurements})
          end
        end,
        nil
      )

      # Schedule 5 messages quickly (no sleep) with a longer debounce window
      for seq <- 1..5 do
        :ok = Debouncer.schedule(session.id, agent.id, "user-123", seq, 100)
      end

      # Wait for debounce to fire
      assert_receive {:telemetry, :debounce, measurements}, 300

      # Should batch all 5 messages
      assert measurements.batched_messages == 5

      :telemetry.detach(handler_id)
    end
  end

  describe "telemetry" do
    test "emits debounce telemetry with correct measurements", %{session: session, agent: agent} do
      handler_id = "test-debounce-telemetry-#{:erlang.unique_integer()}"
      test_pid = self()
      session_id = session.id

      :telemetry.attach(
        handler_id,
        [:fleetlm, :agent, :debounce],
        fn _event, measurements, metadata, _config ->
          # Only send to test if it's for our session
          if metadata.session_id == session_id do
            send(test_pid, {:telemetry, measurements, metadata})
          end
        end,
        nil
      )

      # Schedule messages with contiguous sequences (as in real usage)
      :ok = Debouncer.schedule(session.id, agent.id, "user-123", 1, 50)
      :ok = Debouncer.schedule(session.id, agent.id, "user-123", 2, 50)
      :ok = Debouncer.schedule(session.id, agent.id, "user-123", 3, 50)

      # Wait for dispatch
      assert_receive {:telemetry, measurements, metadata}, 200

      # Verify measurements
      assert measurements.batched_messages == 3
      assert measurements.delay >= 0

      # Verify metadata
      assert metadata.agent_id == agent.id
      assert metadata.session_id == session.id
      assert metadata.window_ms == agent.debounce_window_ms

      :telemetry.detach(handler_id)
    end
  end

  describe "configuration" do
    test "uses agent's configured debounce window" do
      # Create a dedicated agent and session for this test
      agent = create_agent("custom-agent-#{:erlang.unique_integer()}", %{debounce_window_ms: 1000})
      session = create_test_session("custom-user-#{:erlang.unique_integer()}", agent.id)

      handler_id = "test-custom-window-#{:erlang.unique_integer()}"
      test_pid = self()
      session_id = session.id

      :telemetry.attach(
        handler_id,
        [:fleetlm, :agent, :debounce],
        fn _event, _measurements, metadata, _config ->
          # Only send to test if it's for our session
          if metadata.session_id == session_id do
            send(test_pid, {:window_ms, metadata.window_ms})
          end
        end,
        nil
      )

      :ok = Debouncer.schedule(session.id, agent.id, "custom-user", 1, 100)

      # Should use agent's configured window
      assert_receive {:window_ms, window_ms}, 1500
      assert window_ms == 1000

      :telemetry.detach(handler_id)
    end
  end

  # Helper to create agent with custom debounce window
  defp create_agent(id, attrs) do
    default_attrs = %{
      id: id,
      name: "Test Agent #{id}",
      origin_url: "http://localhost:3000",
      debounce_window_ms: 500
    }

    {:ok, agent} = Fleetlm.Agent.create(Map.merge(default_attrs, attrs))
    agent
  end
end
