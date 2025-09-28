defmodule Fleetlm.Integration.StressTest do
  @moduledoc """
  Stress tests for high-load scenarios that expose race conditions
  and performance bottlenecks in the distributed system.
  """
  use Fleetlm.DataCase
  @moduletag :stress

  alias Fleetlm.Runtime.Gateway
  alias Fleetlm.Runtime.Sharding.HashRing
  alias Fleetlm.Conversation.Participants
  alias Fleetlm.Conversation

  import Fleetlm.TestSupport.Sharding

  @high_concurrency 50
  @burst_size 20
  @session_count 10

  setup do
    Application.put_env(:fleetlm, :persistence_worker_mode, :live)

    # Setup test participants
    {:ok, _} =
      Participants.upsert_participant(%{
        id: "user:stress:sender",
        kind: "user",
        display_name: "Stress Sender"
      })

    {:ok, _} =
      Participants.upsert_participant(%{
        id: "user:stress:receiver",
        kind: "user",
        display_name: "Stress Receiver"
      })

    # Create multiple sessions for load distribution
    sessions =
      for _ <- 1..@session_count do
        {:ok, session} =
          Conversation.start_session(%{
            initiator_id: "user:stress:sender",
            peer_id: "user:stress:receiver"
          })

        slot = HashRing.slot_for_session(session.id)
        _pid = ensure_slot!(slot)
        session
      end

    on_exit(fn ->
      Application.put_env(:fleetlm, :persistence_worker_mode, :noop)
    end)

    {:ok, sessions: sessions}
  end

  describe "high concurrency stress tests" do
    test "burst message sending doesn't cause data corruption", %{sessions: sessions} do
      # Send burst of messages to each session concurrently
      burst_tasks =
        for session <- sessions do
          Task.async(fn ->
            # Each task sends a burst of messages
            message_tasks =
              for i <- 1..@burst_size do
                Task.async(fn ->
                  Gateway.append_message(session.id, %{
                    sender_id: session.initiator_id,
                    kind: "text",
                    content: %{text: "burst-#{session.id}-#{i}", sequence: i},
                    idempotency_key: "burst-#{session.id}-#{i}"
                  })
                end)
              end

            results = Enum.map(message_tasks, &Task.await(&1, 10_000))
            {session.id, results}
          end)
        end

      # Wait for all burst tasks to complete
      all_results = Enum.map(burst_tasks, &Task.await(&1, 15_000))

      # Verify data integrity across all sessions
      for {session_id, results} <- all_results do
        successful_count = Enum.count(results, &match?({:ok, _}, &1))
        messages = Gateway.replay_messages(session_id, limit: @burst_size + 5)

        # Should have all messages (or most with some tolerance for failures)
        assert length(messages) >= successful_count * 0.9

        # All message IDs should be unique
        message_ids = Enum.map(messages, & &1.id)
        assert length(message_ids) == length(Enum.uniq(message_ids))

        # Verify sequence integrity within each session
        sequences =
          for msg <- messages do
            get_in(msg.content, ["sequence"])
          end

        valid_sequences = Enum.reject(sequences, &is_nil/1)
        assert length(valid_sequences) > 0
        assert Enum.sort(valid_sequences) == Enum.to_list(1..length(valid_sequences))
      end
    end

    test "persistence workers handle queue overflow gracefully", %{sessions: sessions} do
      # Create massive concurrent load to overflow persistence queues
      flood_tasks =
        for session <- sessions do
          Task.async(fn ->
            # Send many messages rapidly to overwhelm persistence worker
            results =
              for i <- 1..@high_concurrency do
                result =
                  Gateway.append_message(session.id, %{
                    sender_id: session.initiator_id,
                    kind: "text",
                    content: %{text: "flood-#{i}", flood_id: i},
                    idempotency_key: "flood-#{session.id}-#{i}"
                  })

                # Small random delay to create uneven load
                if rem(i, 10) == 0 do
                  Process.sleep(:rand.uniform(5))
                end

                result
              end

            {session.id, results}
          end)
        end

      # Monitor system resources during flood
      memory_before = :erlang.memory(:total)
      process_count_before = length(Process.list())

      # Wait for flood to complete
      flood_results = Enum.map(flood_tasks, &Task.await(&1, 30_000))

      # Check system stability after flood
      memory_after = :erlang.memory(:total)
      process_count_after = length(Process.list())

      # Memory shouldn't grow excessively (within 50% of original)
      assert memory_after < memory_before * 1.5

      # Process count should be stable (within 20% of original)
      assert abs(process_count_after - process_count_before) < process_count_before * 0.2

      # Verify all persistence workers are still responding
      for session <- sessions do
        slot = HashRing.slot_for_session(session.id)
        _slot_pid = slot_pid!(slot)

        # Try to send one more message to verify system is responsive
        assert {:ok, _} =
                 Gateway.append_message(session.id, %{
                   sender_id: session.initiator_id,
                   kind: "text",
                   content: %{text: "post-flood-test"},
                   idempotency_key: "post-flood-#{session.id}"
                 })
      end

      # Verify eventual consistency - all messages should eventually be persisted
      # Give time for persistence workers to catch up
      Process.sleep(5_000)

      for {session_id, results} <- flood_results do
        successful_count = Enum.count(results, &match?({:ok, _}, &1))
        messages = Gateway.replay_messages(session_id, limit: @high_concurrency + 10)

        # Should have most messages persisted (allowing for some failures under load)
        assert length(messages) >= successful_count * 0.8
      end
    end

    test "router retry logic doesn't cause exponential amplification", %{sessions: [session | _]} do
      # Get the slot and simulate instability
      slot = HashRing.slot_for_session(session.id)
      original_pid = slot_pid!(slot)

      # Create many concurrent requests that will hit retry logic
      retry_tasks =
        for i <- 1..20 do
          Task.async(fn ->
            # Kill slot at random times to trigger retries
            if rem(i, 5) == 0 do
              try do
                Process.exit(original_pid, :kill)
              catch
                # Process might already be dead
                _, _ -> :ok
              end

              # Give time for restart
              Process.sleep(50)
              _ = ensure_slot!(slot)
            end

            # Send message that might hit retry logic
            start_time = System.monotonic_time(:millisecond)

            result =
              Gateway.append_message(session.id, %{
                sender_id: session.initiator_id,
                kind: "text",
                content: %{text: "retry-test-#{i}"},
                idempotency_key: "retry-test-#{i}"
              })

            end_time = System.monotonic_time(:millisecond)
            duration = end_time - start_time

            {i, result, duration}
          end)
        end

      # Monitor for excessive retry activity
      results = Enum.map(retry_tasks, &Task.await(&1, 15_000))

      # Verify retry behavior is reasonable
      durations = for {_i, _result, duration} <- results, do: duration
      max_duration = Enum.max(durations)
      avg_duration = Enum.sum(durations) / length(durations)

      # No single request should take more than 10 seconds (router has reasonable timeouts)
      assert max_duration < 10_000

      # Average duration should be reasonable (under 1 second on average)
      assert avg_duration < 1_000

      # Most requests should succeed despite instability
      successful_count =
        Enum.count(results, fn {_i, result, _duration} ->
          match?({:ok, _}, result)
        end)

      # At least 70% success rate
      assert successful_count >= length(results) * 0.7
    end

    test "idempotency cache doesn't leak memory under load", %{sessions: [session | _]} do
      slot = HashRing.slot_for_session(session.id)
      slot_pid = slot_pid!(slot)

      # Get initial memory usage of slot process
      memory_before = process_memory(slot_pid)

      # Send many messages with different idempotency keys
      for batch <- 1..10 do
        batch_tasks =
          for i <- 1..50 do
            Task.async(fn ->
              Gateway.append_message(session.id, %{
                sender_id: session.initiator_id,
                kind: "text",
                content: %{text: "memory-test-#{batch}-#{i}"},
                idempotency_key: "memory-test-#{batch}-#{i}"
              })
            end)
          end

        Enum.each(batch_tasks, &Task.await(&1, 5_000))

        # Force garbage collection
        :erlang.garbage_collect(slot_pid)
        Process.sleep(100)
      end

      # Check memory usage after load
      memory_after = process_memory(slot_pid)

      # Memory shouldn't grow excessively (idempotency cache should have TTL)
      memory_growth = (memory_after - memory_before) / memory_before
      # Less than 200% growth
      assert memory_growth < 2.0

      # Send duplicate messages to test cache effectiveness
      duplicate_results =
        for _ <- 1..10 do
          Gateway.append_message(session.id, %{
            sender_id: session.initiator_id,
            kind: "text",
            content: %{text: "duplicate-test"},
            idempotency_key: "duplicate-key"
          })
        end

      # All duplicates should return the same message ID
      message_ids = for {:ok, msg} <- duplicate_results, do: msg.id
      assert length(Enum.uniq(message_ids)) == 1
    end

    test "disk log doesn't become a bottleneck under concurrent writes", %{sessions: sessions} do
      # Monitor disk log performance across multiple slots
      log_performance_tasks =
        for session <- sessions do
          Task.async(fn ->
            # Send messages and measure write latency
            latencies =
              for i <- 1..20 do
                start_time = System.monotonic_time(:microsecond)

                result =
                  Gateway.append_message(session.id, %{
                    sender_id: session.initiator_id,
                    kind: "text",
                    content: %{text: "latency-test-#{i}"},
                    idempotency_key: "latency-test-#{session.id}-#{i}"
                  })

                end_time = System.monotonic_time(:microsecond)
                latency = end_time - start_time

                case result do
                  {:ok, _} -> latency
                  _ -> nil
                end
              end

            valid_latencies = Enum.reject(latencies, &is_nil/1)
            {session.id, valid_latencies}
          end)
        end

      # Wait for all performance tests to complete
      performance_results = Enum.map(log_performance_tasks, &Task.await(&1, 15_000))

      # Analyze performance characteristics
      all_latencies = for {_session_id, latencies} <- performance_results, do: latencies
      flat_latencies = List.flatten(all_latencies)

      # Convert to milliseconds for easier analysis
      latencies_ms = Enum.map(flat_latencies, &(&1 / 1000))

      avg_latency = Enum.sum(latencies_ms) / length(latencies_ms)
      max_latency = Enum.max(latencies_ms)
      p95_latency = Enum.at(Enum.sort(latencies_ms), round(length(latencies_ms) * 0.95))

      # Performance assertions (these are reasonable for disk writes)
      # Average under 100ms
      assert avg_latency < 100
      # Max under 1 second
      assert max_latency < 1000
      # 95th percentile under 200ms
      assert p95_latency < 200

      # Verify no messages were lost despite concurrent load
      for {session_id, _latencies} <- performance_results do
        messages = Gateway.replay_messages(session_id, limit: 25)
        # Allow for some failures under load
        assert length(messages) >= 18
      end
    end
  end

  # Helper functions

  defp process_memory(pid) do
    case Process.info(pid, :memory) do
      {:memory, bytes} -> bytes
      _ -> 0
    end
  end
end
