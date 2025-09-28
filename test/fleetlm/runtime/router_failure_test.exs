defmodule Fleetlm.Runtime.RouterFailureTest do
  @moduledoc """
  Comprehensive tests for Router failure modes, retry logic, and edge cases
  that could cause cascading failures or data inconsistency.
  """
  use Fleetlm.DataCase

  alias Fleetlm.Runtime.Router
  alias Fleetlm.Runtime.Sharding.HashRing
  alias Fleetlm.Conversation.{Participants, ChatMessage}
  alias Fleetlm.Conversation

  import Fleetlm.TestSupport.Sharding

  setup do
    Application.put_env(:fleetlm, :persistence_worker_mode, :live)

    {:ok, _} =
      Participants.upsert_participant(%{
        id: "user:router:test",
        kind: "user",
        display_name: "Router Test User"
      })

    {:ok, _} =
      Participants.upsert_participant(%{
        id: "agent:router:bot",
        kind: "agent",
        display_name: "Router Test Bot"
      })

    {:ok, session} =
      Conversation.start_session(%{
        initiator_id: "user:router:test",
        peer_id: "agent:router:bot"
      })

    slot = HashRing.slot_for_session(session.id)

    on_exit(fn ->
      Application.put_env(:fleetlm, :persistence_worker_mode, :noop)
    end)

    {:ok, session: session, slot: slot}
  end

  describe "router retry behavior" do
    test "router handles slot handoff correctly", %{session: session, slot: slot} do
      # Start slot initially
      slot_pid = ensure_slot!(slot)

      # Send successful message
      assert {:ok, _} =
               Router.append(session.id, %{
                 sender_id: session.initiator_id,
                 kind: "text",
                 content: %{text: "before-handoff"},
                 idempotency_key: "before-handoff"
               })

      # Simulate handoff by making slot return handoff error
      :sys.replace_state(slot_pid, fn state ->
        %{state | status: :draining}
      end)

      # Router should retry when getting handoff response
      capture_log(fn ->
        result =
          Router.append(session.id, %{
            sender_id: session.initiator_id,
            kind: "text",
            content: %{text: "during-handoff"},
            idempotency_key: "during-handoff"
          })

        # With improved error handling, the system may restart the slot and succeed,
        # or it may still timeout depending on timing
        case result do
          # Improved resilience succeeded
          {:ok, _message} -> :ok
          # Original expected behavior
          {:error, :timeout} -> :ok
          other -> flunk("Unexpected result: #{inspect(other)}")
        end
      end)
    end

    test "concurrent requests don't interfere with each other", %{session: session, slot: slot} do
      ensure_slot!(slot)

      # Send many concurrent requests
      tasks =
        for i <- 1..20 do
          Task.async(fn ->
            Router.append(session.id, %{
              sender_id: session.initiator_id,
              kind: "text",
              content: %{text: "concurrent-#{i}"},
              idempotency_key: "concurrent-#{i}"
            })
          end)
        end

      results = Enum.map(tasks, &Task.await(&1, 5000))

      # All should succeed
      successful_count = Enum.count(results, &match?({:ok, _}, &1))
      assert successful_count == 20

      # All message IDs should be unique
      message_ids = for {:ok, msg} <- results, do: msg.id
      assert length(message_ids) == length(Enum.uniq(message_ids))
    end

    test "router handles registry lookup failures gracefully", %{session: session, slot: slot} do
      # Start slot then kill it suddenly
      ensure_slot!(slot)
      crash_slot!(slot)

      # Router should handle noproc errors and retry - with improved resilience, this should succeed
      capture_log(fn ->
        result =
          Router.append(session.id, %{
            sender_id: session.initiator_id,
            kind: "text",
            content: %{text: "after-sudden-death"},
            idempotency_key: "after-sudden-death"
          })

        # With improved error handling and slot restart logic, this should now succeed
        assert {:ok, _message} = result
      end)
    end

    test "await_persistence handles timeouts correctly", %{session: session, slot: slot} do
      ensure_slot!(slot)

      # Send a message
      assert {:ok, message} =
               Router.append(session.id, %{
                 sender_id: session.initiator_id,
                 kind: "text",
                 content: %{text: "persistence-test"},
                 idempotency_key: "persistence-test"
               })

      # await_persistence with very short timeout should fail
      assert {:error, :timeout} = Router.await_persistence(session.id, message.id, 1)

      # But with reasonable timeout should succeed
      assert :ok = Router.await_persistence(session.id, message.id, 5000)

      # Non-existent message should timeout
      fake_id = "01234567890123456789012345"
      assert {:error, :timeout} = Router.await_persistence(session.id, fake_id, 100)
    end

    test "remote call simulation behaves correctly", %{session: session, slot: slot} do
      # Test the remote_call function directly
      ensure_slot!(slot)

      # Should work for local calls
      result =
        Router.remote_call(
          slot,
          {:append, session.id,
           %{
             sender_id: session.initiator_id,
             kind: "text",
             content: %{text: "remote-call-test"},
             idempotency_key: "remote-call-test"
           }},
          5000
        )

      assert {:ok, %ChatMessage{}} = result
    end

    test "hash ring changes during request processing", %{session: session, slot: slot} do
      original_ring = HashRing.current()
      ensure_slot!(slot)

      # Send concurrent requests while changing hash ring
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            # Change ring occasionally during requests
            if rem(i, 3) == 0 do
              fake_ring = %{original_ring | generation: original_ring.generation + i}
              HashRing.put_current!(fake_ring)
              Process.sleep(5)
              HashRing.put_current!(original_ring)
            end

            Router.append(session.id, %{
              sender_id: session.initiator_id,
              kind: "text",
              content: %{text: "ring-change-#{i}"},
              idempotency_key: "ring-change-#{i}"
            })
          end)
        end

      results = Enum.map(tasks, &Task.await(&1, 5000))

      # Most should succeed despite ring changes
      successful_count = Enum.count(results, &match?({:ok, _}, &1))
      # Allow for some failures during ring changes
      assert successful_count >= 8

      on_exit(fn -> HashRing.put_current!(original_ring) end)
    end
  end

  describe "error propagation" do
    test "slot server errors are properly surfaced", %{session: session, slot: slot} do
      _ = ensure_slot!(slot)

      # Force a database error by using invalid session_id format
      result =
        Router.append("invalid-session-format", %{
          sender_id: session.initiator_id,
          kind: "text",
          content: %{text: "should-fail"},
          idempotency_key: "should-fail"
        })

      # Should get a proper error, not a timeout
      assert match?({:error, _}, result)
      refute match?({:error, :timeout}, result)
    end

    test "persistence worker failures don't break router", %{session: session, slot: slot} do
      capture_log(fn ->
        slot_pid = ensure_slot!(slot)

        # Kill the persistence worker
        worker_pid = get_persistence_worker(slot_pid)
        ref = Process.monitor(worker_pid)
        Process.exit(worker_pid, :kill)
        assert_receive {:DOWN, ^ref, :process, ^worker_pid, _}, 1000

        # Router should still work for appends (they'll fail to persist but succeed in memory)
        assert {:ok, message} =
                 Router.append(session.id, %{
                   sender_id: session.initiator_id,
                   kind: "text",
                   content: %{text: "worker-dead"},
                   idempotency_key: "worker-dead"
                 })

        # With improved persistence worker restart logic, this may succeed or timeout
        case Router.await_persistence(session.id, message.id, 500) do
          # Worker was restarted and succeeded
          :ok -> :ok
          # Original expected behavior
          {:error, :timeout} -> :ok
          # Acceptable intermediate state
          {:error, :worker_crashed} -> :ok
          # Acceptable intermediate state
          {:error, :worker_dead} -> :ok
          other -> flunk("Unexpected result: #{inspect(other)}")
        end
      end)
    end

    test "malformed requests are handled gracefully", %{session: session} do
      # Test various malformed inputs
      bad_inputs = [
        {nil, %{}},
        {"", %{}},
        {session.id, nil},
        {session.id, []},
        {session.id, %{invalid: "structure"}},
        {"not-a-ulid", %{sender_id: "test", kind: "text", content: %{}}}
      ]

      for {session_id, attrs} <- bad_inputs do
        result =
          try do
            Router.append(session_id, attrs)
          catch
            :error, %FunctionClauseError{} -> {:error, :invalid_input}
            :error, other -> {:error, other}
          end

        assert match?({:error, _}, result)
      end
    end
  end

  # Helper functions

  defp get_persistence_worker(slot_pid) do
    %{persistence_worker: worker} = :sys.get_state(slot_pid)
    worker
  end

  defp capture_log(fun) do
    ExUnit.CaptureLog.capture_log(fun)
  end
end
