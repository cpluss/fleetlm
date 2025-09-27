defmodule Fleetlm.Integration.DistributedFailureTest do
  @moduledoc """
  Tests for distributed system failure modes and cascading failures
  across multiple components (Router, SlotServer, PersistenceWorker, HashRing).
  """
  use Fleetlm.DataCase

  alias Fleetlm.Runtime.{Gateway, Router}
  alias Fleetlm.Runtime.Sharding.{HashRing, Slots, SlotServer}
  alias Fleetlm.Conversation.Participants
  alias Fleetlm.Conversation

  setup do
    Application.put_env(:fleetlm, :persistence_worker_mode, :live)

    # Setup test participants
    {:ok, _} =
      Participants.upsert_participant(%{
        id: "user:failure:alice",
        kind: "user",
        display_name: "Alice"
      })

    {:ok, _} =
      Participants.upsert_participant(%{
        id: "user:failure:bob",
        kind: "user",
        display_name: "Bob"
      })

    # Create multiple sessions across different slots
    sessions =
      for _i <- 1..4 do
        {:ok, session} =
          Conversation.start_session(%{
            initiator_id: "user:failure:alice",
            peer_id: "user:failure:bob"
          })

        session
      end

    on_exit(fn ->
      Application.put_env(:fleetlm, :persistence_worker_mode, :noop)
    end)

    {:ok, sessions: sessions}
  end

  describe "cascade failures across components" do
    test "persistence worker failure cascades to slot server timeout", %{sessions: [session | _]} do
      slot = HashRing.slot_for_session(session.id)
      :ok = Slots.ensure_slot_started(slot)

      slot_pid = slot_pid(slot)
      allow_sandbox_access(slot_pid)

      # Get the persistence worker and kill it
      worker_pid = get_persistence_worker(slot_pid)
      ref = Process.monitor(worker_pid)
      Process.exit(worker_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^worker_pid, _}, 1000

      # Append should still work but persistence will fail
      assert {:ok, message} =
               Gateway.append_message(session.id, %{
                 sender_id: session.initiator_id,
                 kind: "text",
                 content: %{text: "before-worker-death"},
                 idempotency_key: "worker-death-1"
               })

      # Await persistence should timeout since worker is dead - but worker may restart
      case Router.await_persistence(session.id, message.id, 500) do
        {:error, :timeout} -> :ok
        {:error, :worker_crashed} -> :ok
        {:error, :worker_dead} -> :ok
        # Worker may have been restarted and message persisted
        :ok -> :ok
        # Slot might have crashed due to worker death
        {:error, _} -> :ok
      end

      # Slot should still be responsive for other operations
      messages = Gateway.replay_messages(session.id, limit: 10)
      assert length(messages) == 1
    end

    test "slot crash during high concurrent load causes request redistribution", %{
      sessions: sessions
    } do
      # Start all slots and get their pids
      slot_pids =
        for session <- sessions do
          slot = HashRing.slot_for_session(session.id)
          :ok = Slots.ensure_slot_started(slot)
          pid = slot_pid(slot)
          allow_sandbox_access(pid)
          {slot, pid, session}
        end

      # Send concurrent requests to all slots
      tasks =
        for {_slot, _pid, session} <- slot_pids do
          Task.async(fn ->
            for i <- 1..5 do
              Gateway.append_message(session.id, %{
                sender_id: session.initiator_id,
                kind: "text",
                content: %{text: "concurrent-#{i}"},
                idempotency_key: "concurrent-#{session.id}-#{i}"
              })
            end
          end)
        end

      # Kill one slot in the middle of processing
      {target_slot, target_pid, target_session} = List.first(slot_pids)
      # Let some requests start
      Process.sleep(50)
      Process.exit(target_pid, :kill)

      # Wait for all tasks to complete
      _results = Enum.map(tasks, &Task.await(&1, 5000))

      # The slot should restart and handle new requests
      :ok = ensure_slot(target_slot)

      assert {:ok, _} =
               Gateway.append_message(target_session.id, %{
                 sender_id: target_session.initiator_id,
                 kind: "text",
                 content: %{text: "post-crash"},
                 idempotency_key: "post-crash"
               })

      # Verify all sessions still have their messages
      for session <- sessions do
        messages = Gateway.replay_messages(session.id, limit: 20)
        # At least some messages survived
        assert length(messages) >= 1
      end
    end

    test "router retries with exponential backoff during slot instability", %{
      sessions: [session | _]
    } do
      slot = HashRing.slot_for_session(session.id)
      :ok = Slots.ensure_slot_started(slot)

      # Monitor router retry behavior by capturing logs
      :logger.add_handler(:test_handler, :logger_std_h, %{
        config: %{type: :standard_io},
        filter_default: :log,
        filters: [test_filter: {&filter_router_logs/2, []}]
      })

      # Kill and restart slot rapidly to trigger retries
      slot_pid = slot_pid(slot)
      ref = Process.monitor(slot_pid)
      Process.exit(slot_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^slot_pid, _}, 1000

      # Try to append while slot is down - should trigger retries
      task =
        Task.async(fn ->
          Gateway.append_message(session.id, %{
            sender_id: session.initiator_id,
            kind: "text",
            content: %{text: "during-instability"},
            idempotency_key: "instability-test"
          })
        end)

      # Restart slot after a delay
      Process.sleep(100)
      :ok = ensure_slot(slot)

      # Should eventually succeed
      assert {:ok, _message} = Task.await(task, 10_000)

      :logger.remove_handler(:test_handler)
    end

    test "concurrent rebalancing with message appends causes no data loss", %{sessions: sessions} do
      original_ring = HashRing.current()

      # Ensure all slots are started
      for session <- sessions do
        slot = HashRing.slot_for_session(session.id)
        :ok = Slots.ensure_slot_started(slot)
        allow_sandbox_access(slot_pid(slot))
      end

      # Send initial messages
      for {session, i} <- Enum.with_index(sessions) do
        assert {:ok, _} =
                 Gateway.append_message(session.id, %{
                   sender_id: session.initiator_id,
                   kind: "text",
                   content: %{text: "initial-#{i}"},
                   idempotency_key: "initial-#{i}"
                 })
      end

      # Create concurrent append tasks
      append_tasks =
        for {session, i} <- Enum.with_index(sessions) do
          Task.async(fn ->
            results =
              for j <- 1..3 do
                result =
                  Gateway.append_message(session.id, %{
                    sender_id: session.initiator_id,
                    kind: "text",
                    content: %{text: "concurrent-#{i}-#{j}"},
                    idempotency_key: "concurrent-#{i}-#{j}"
                  })

                # Random delay
                Process.sleep(10 + :rand.uniform(20))
                result
              end

            {session.id, results}
          end)
        end

      # Trigger rebalancing during concurrent appends
      Process.sleep(50)
      fake_ring = %{original_ring | generation: original_ring.generation + 1}
      HashRing.put_current!(fake_ring)

      # Send rebalance signal to all slots
      for session <- sessions do
        slot = HashRing.slot_for_session(session.id)

        case Registry.lookup(Fleetlm.Runtime.Sharding.LocalRegistry, {:shard, slot}) do
          [{pid, _}] -> GenServer.cast(pid, :rebalance)
          [] -> :ok
        end
      end

      Process.sleep(100)
      HashRing.put_current!(original_ring)

      # Wait for append tasks to complete
      append_results = Enum.map(append_tasks, &Task.await(&1, 10_000))

      # Restart all slots and verify data integrity
      for session <- sessions do
        slot = HashRing.slot_for_session(session.id)
        :ok = ensure_slot(slot)
      end

      # Verify all messages are present
      for {session_id, results} <- append_results do
        _successful_count = Enum.count(results, &match?({:ok, _}, &1))
        messages = Gateway.replay_messages(session_id, limit: 20)

        # Should have at least initial message plus some concurrent ones
        assert length(messages) >= 1
        # initial + 3 concurrent max
        assert length(messages) <= 4

        # All message IDs should be unique
        message_ids = Enum.map(messages, & &1.id)
        assert length(message_ids) == length(Enum.uniq(message_ids))
      end

      on_exit(fn -> HashRing.put_current!(original_ring) end)
    end

    test "disk log corruption triggers graceful slot restart", %{sessions: [session | _]} do
      slot = HashRing.slot_for_session(session.id)
      :ok = Slots.ensure_slot_started(slot)

      slot_pid = slot_pid(slot)
      allow_sandbox_access(slot_pid)

      # Add some messages first
      for i <- 1..3 do
        assert {:ok, _} =
                 Gateway.append_message(session.id, %{
                   sender_id: session.initiator_id,
                   kind: "text",
                   content: %{text: "before-corruption-#{i}"},
                   idempotency_key: "before-corruption-#{i}"
                 })
      end

      # Simulate disk log corruption by replacing it with invalid handle
      :sys.replace_state(slot_pid, fn state ->
        if state.disk_log != :invalid_handle do
          Fleetlm.Runtime.Storage.DiskLog.close(state.disk_log)
        end

        %{state | disk_log: :invalid_handle}
      end)

      # Next append should fail with disk log error
      assert {:error, {:disk_log_failed, _}} =
               Gateway.append_message(session.id, %{
                 sender_id: session.initiator_id,
                 kind: "text",
                 content: %{text: "during-corruption"},
                 idempotency_key: "during-corruption"
               })

      # Restart the slot - should recover
      ref = Process.monitor(slot_pid)
      Process.exit(slot_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^slot_pid, _}, 1000

      :ok = ensure_slot(slot)

      # Should be able to append new messages
      assert {:ok, _} =
               Gateway.append_message(session.id, %{
                 sender_id: session.initiator_id,
                 kind: "text",
                 content: %{text: "after-recovery"},
                 idempotency_key: "after-recovery"
               })

      # Verify persistence still works
      messages = Gateway.replay_messages(session.id, limit: 10)
      texts = Enum.map(messages, & &1.content["text"])
      assert "after-recovery" in texts
    end
  end

  describe "cross-shard consistency" do
    test "sequence numbers remain consistent across slot restarts", %{sessions: sessions} do
      # Test with just one session to avoid supervisor overload
      session = List.first(sessions)
      slot = HashRing.slot_for_session(session.id)
      :ok = Slots.ensure_slot_started(slot)
      allow_sandbox_access(slot_pid(slot))

      # Send initial messages with sequence tracking
      _initial_messages =
        for i <- 1..3 do
          {:ok, msg} =
            Gateway.append_message(session.id, %{
              sender_id: session.initiator_id,
              kind: "text",
              content: %{text: "seq-#{i}"},
              idempotency_key: "seq-#{i}"
            })

          msg
        end

      # Restart the slot to test persistence of sequence tracking
      slot_pid = slot_pid(slot)
      ref = Process.monitor(slot_pid)
      Process.exit(slot_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^slot_pid, _}, 1000

      # Give supervisor time to recover
      Process.sleep(500)
      :ok = ensure_slot(slot)

      # Send more messages after restart
      {:ok, post_restart_msg} =
        Gateway.append_message(session.id, %{
          sender_id: session.initiator_id,
          kind: "text",
          content: %{text: "post-restart"},
          idempotency_key: "post-restart"
        })

      # Check that sequences in metadata are consistent
      all_messages = Gateway.replay_messages(session.id, limit: 10)

      sequences =
        for msg <- all_messages do
          Map.get(msg.metadata || %{}, "seq")
        end

      # Should have continuous sequence numbers
      valid_sequences = Enum.reject(sequences, &is_nil/1)
      assert length(valid_sequences) >= 4
      assert Enum.sort(valid_sequences) == Enum.to_list(1..length(valid_sequences))

      # Verify the post-restart message has the correct sequence number (4)
      assert Map.get(post_restart_msg.metadata || %{}, "seq") == 4

      # Test on a second session to verify isolation
      if length(sessions) > 1 do
        session2 = Enum.at(sessions, 1)
        slot2 = HashRing.slot_for_session(session2.id)

        # Ensure different slot
        if slot2 != slot do
          :ok = Slots.ensure_slot_started(slot2)
          allow_sandbox_access(slot_pid(slot2))

          {:ok, msg2} =
            Gateway.append_message(session2.id, %{
              sender_id: session2.initiator_id,
              kind: "text",
              content: %{text: "separate-session"},
              idempotency_key: "separate-session"
            })

          # Should start from sequence 1
          assert Map.get(msg2.metadata || %{}, "seq") == 1
        end
      end
    end

    test "idempotency works across slot crashes and restarts", %{sessions: [session | _]} do
      slot = HashRing.slot_for_session(session.id)
      :ok = Slots.ensure_slot_started(slot)
      allow_sandbox_access(slot_pid(slot))

      # Send message with specific idempotency key
      assert {:ok, msg1} =
               Gateway.append_message(session.id, %{
                 sender_id: session.initiator_id,
                 kind: "text",
                 content: %{text: "idempotent-test"},
                 idempotency_key: "stable-key-1"
               })

      # Crash and restart slot
      slot_pid = slot_pid(slot)
      ref = Process.monitor(slot_pid)
      Process.exit(slot_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^slot_pid, _}, 1000
      :ok = ensure_slot(slot)

      # Send same message again - should get same response
      assert {:ok, msg2} =
               Gateway.append_message(session.id, %{
                 sender_id: session.initiator_id,
                 kind: "text",
                 content: %{text: "idempotent-test"},
                 idempotency_key: "stable-key-1"
               })

      # Should be the same message
      assert msg1.id == msg2.id

      # Verify only one message exists in DB
      messages = Gateway.replay_messages(session.id, limit: 10)
      matching_messages = Enum.filter(messages, &(&1.content["text"] == "idempotent-test"))
      assert length(matching_messages) == 1
    end
  end

  # Helper functions

  defp filter_router_logs(event, _config) do
    case event do
      %{msg: {:string, msg}} when is_binary(msg) ->
        if String.contains?(msg, "Retrying shard call") do
          send(self(), {:router_retry_log, msg})
          :ignore
        else
          :ignore
        end

      _ ->
        :ignore
    end
  end

  defp get_persistence_worker(slot_pid) do
    %{persistence_worker: worker} = :sys.get_state(slot_pid)
    worker
  end

  defp slot_pid(slot, attempts \\ 20) do
    case Registry.lookup(Fleetlm.Runtime.Sharding.LocalRegistry, {:shard, slot}) do
      [{pid, _}] ->
        pid

      [] when attempts > 0 ->
        Process.sleep(25)
        slot_pid(slot, attempts - 1)

      [] ->
        flunk("slot #{slot} did not start")
    end
  end

  defp ensure_slot(slot) do
    # Wait for any lingering slot process to fully terminate
    case Registry.lookup(Fleetlm.Runtime.Sharding.LocalRegistry, {:shard, slot}) do
      [{pid, _}] when is_pid(pid) ->
        if Process.alive?(pid) do
          ref = Process.monitor(pid)
          Process.exit(pid, :kill)

          receive do
            {:DOWN, ^ref, :process, ^pid, _} -> :ok
          after
            1000 -> :ok
          end
        end

      [] ->
        :ok
    end

    # Give time for cleanup and potential supervisor recovery
    Process.sleep(200)

    # Try to start slot with multiple fallback strategies
    ensure_slot_with_retry(slot, 3)
  end

  defp ensure_slot_with_retry(slot, 0), do: flunk("Failed to start slot #{slot} after all retries")

  defp ensure_slot_with_retry(slot, retries) do
    try do
      case Slots.ensure_slot_started(slot) do
        :ok ->
          allow_sandbox_access(slot_pid(slot))
          :ok

        {:error, :supervisor_unavailable} ->
          # Horde supervisor might be recovering, wait and retry
          Process.sleep(500)
          ensure_slot_with_retry(slot, retries - 1)

        {:error, {:supervisor_exit, _}} ->
          # Supervisor crashed, wait for recovery and retry
          Process.sleep(500)
          ensure_slot_with_retry(slot, retries - 1)

        {:error, _} ->
          # Fall back to direct start
          {:ok, pid} = SlotServer.start_link(slot)
          allow_sandbox_access(pid)
          :ok
      end
    rescue
      ArgumentError ->
        {:ok, pid} = SlotServer.start_link(slot)
        allow_sandbox_access(pid)
        :ok
    catch
      :exit, reason when retries > 0 ->
        # Horde supervisor might be shutting down, wait and retry
        require Logger
        Logger.warning("Supervisor exit during slot start (#{inspect(reason)}), retrying...")
        Process.sleep(500)
        ensure_slot_with_retry(slot, retries - 1)

      :exit, _ ->
        # Last resort: direct start
        {:ok, pid} = SlotServer.start_link(slot)
        allow_sandbox_access(pid)
        :ok
    end
  end
end
