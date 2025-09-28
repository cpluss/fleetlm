defmodule Fleetlm.Integration.ClusterCoordinationTest do
  @moduledoc """
  Tests for multi-node cluster coordination and split-brain scenarios.
  Since we can't easily spin up multiple nodes in tests, we simulate
  multi-node behavior by manipulating hash rings and testing coordination logic.
  """
  use Fleetlm.DataCase
  @moduletag :stress

  alias Fleetlm.Runtime.{Gateway, Router}
  alias Fleetlm.Runtime.Sharding.{HashRing, Manager}
  alias Fleetlm.Conversation.Participants
  alias Fleetlm.Conversation

  import Fleetlm.TestSupport.Sharding

  setup do
    Application.put_env(:fleetlm, :persistence_worker_mode, :live)

    # Setup test participants
    {:ok, _} =
      Participants.upsert_participant(%{
        id: "user:cluster:alice",
        kind: "user",
        display_name: "Alice"
      })

    {:ok, _} =
      Participants.upsert_participant(%{
        id: "user:cluster:bob",
        kind: "user",
        display_name: "Bob"
      })

    # Store original ring for cleanup
    original_ring = HashRing.current()

    on_exit(fn ->
      Application.put_env(:fleetlm, :persistence_worker_mode, :noop)
      HashRing.put_current!(original_ring)
    end)

    {:ok, original_ring: original_ring}
  end

  describe "hash ring coordination" do
    test "concurrent ring updates maintain consistency", %{original_ring: original_ring} do
      # Create sessions that will be affected by ring changes
      sessions =
        for _ <- 1..8 do
          {:ok, session} =
            Conversation.start_session(%{
              initiator_id: "user:cluster:alice",
              peer_id: "user:cluster:bob"
            })

          session
        end

      # Start slots for all sessions
      slot_assignments =
        for session <- sessions do
          slot = HashRing.slot_for_session(session.id)
          _pid = ensure_slot!(slot)
          {session, slot}
        end

      # Simulate rapid ring changes (like during cluster instability)
      fake_nodes = [Node.self(), :node2@test, :node3@test]

      ring_update_tasks =
        for i <- 1..5 do
          Task.async(fn ->
            # Each task tries to update the ring with different node sets
            node_subset = Enum.take(fake_nodes, rem(i, 3) + 1)
            new_ring = HashRing.build(original_ring.slot_count, node_subset)
            HashRing.put_current!(new_ring)
            Process.sleep(10 + :rand.uniform(20))
            new_ring.generation
          end)
        end

      # Concurrent message sending during ring instability
      message_tasks =
        for {session, _slot} <- slot_assignments do
          Task.async(fn ->
            results =
              for j <- 1..3 do
                try do
                  Gateway.append_message(session.id, %{
                    sender_id: session.initiator_id,
                    kind: "text",
                    content: %{text: "during-ring-change-#{j}"},
                    idempotency_key: "ring-change-#{session.id}-#{j}"
                  })
                rescue
                  error in ErlangError -> {:error, error.original}
                catch
                  :exit, reason -> {:exit, reason}
                end
              end

            {session.id, results}
          end)
        end

      # Wait for all tasks to complete
      _ = Enum.map(ring_update_tasks, &Task.await(&1, 5000))
      message_results = Enum.map(message_tasks, &Task.await(&1, 5000))

      # Restore original ring and verify final state
      HashRing.put_current!(original_ring)

      # Restart all slots to clear any inconsistent state
      for {_session, slot} <- slot_assignments do
        case Registry.lookup(Fleetlm.Runtime.Sharding.LocalRegistry, {:shard, slot}) do
          [{pid, _}] ->
            ref = Process.monitor(pid)
            Process.exit(pid, :kill)
            assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1000

          [] ->
            :ok
        end

        _ = ensure_slot!(slot)
      end

      # Verify data consistency - each session should have coherent message history
      message_results
      |> Enum.filter(fn
        {session_id, _results} when is_binary(session_id) -> true
        _ -> false
      end)
      |> Enum.each(fn {session_id, results} ->
        expected_texts =
          for {:ok, msg} <- results do
            msg.content["text"]
          end

        messages = Gateway.replay_messages(session_id, limit: 20)

        # All stored messages should have unique IDs
        message_ids = Enum.map(messages, & &1.id)
        assert length(message_ids) == length(Enum.uniq(message_ids))

        # We should not lose acknowledged messages even during instability
        observed_texts = MapSet.new(messages, & &1.content["text"])

        Enum.each(expected_texts, fn text ->
          assert MapSet.member?(observed_texts, text),
                 "expected message #{inspect(text)} to be persisted for session #{session_id}"
        end)

        # Ensure we stored at least the number of successful appends
        assert length(messages) >= length(expected_texts)
      end)
    end

    test "slot ownership conflicts are resolved deterministically", %{
      original_ring: original_ring
    } do
      {:ok, session} =
        Conversation.start_session(%{
          initiator_id: "user:cluster:alice",
          peer_id: "user:cluster:bob"
        })

      slot = HashRing.slot_for_session(session.id)

      # Create a ring where slot is assigned to a different node
      fake_ring = %{
        original_ring
        | assignments: Map.put(original_ring.assignments, slot, :fake@node),
          nodes: [Node.self(), :fake@node]
      }

      # Start slot with original ring (should succeed)
      original_pid = ensure_slot!(slot)

      # Send a message
      assert {:ok, _msg1} =
               Gateway.append_message(session.id, %{
                 sender_id: session.initiator_id,
                 kind: "text",
                 content: %{text: "before-conflict"},
                 idempotency_key: "before-conflict"
               })

      # Update ring to assign slot to fake node
      HashRing.put_current!(fake_ring)

      # Trigger rebalance - slot should refuse to start on wrong node
      GenServer.cast(original_pid, :rebalance)
      ref = Process.monitor(original_pid)
      assert_receive {:DOWN, ^ref, :process, ^original_pid, _}, 2000

      # Trying to append should fail since no valid owner
      assert_raise ErlangError, fn ->
        Gateway.append_message(session.id, %{
          sender_id: session.initiator_id,
          kind: "text",
          content: %{text: "during-conflict"},
          idempotency_key: "during-conflict"
        })
      end

      # Restore original ring
      HashRing.put_current!(original_ring)
      _ = ensure_slot!(slot)

      # Should be able to append again
      assert {:ok, _msg2} =
               Gateway.append_message(session.id, %{
                 sender_id: session.initiator_id,
                 kind: "text",
                 content: %{text: "after-resolution"},
                 idempotency_key: "after-resolution"
               })

      # Verify original message is still there
      messages = Gateway.replay_messages(session.id, limit: 10)
      texts = Enum.map(messages, & &1.content["text"])
      assert "before-conflict" in texts
      assert "after-resolution" in texts
      refute "during-conflict" in texts
    end

    test "manager handles rapid node join/leave events", %{original_ring: original_ring} do
      # Capture manager state changes using the supervised instance
      manager_pid =
        Manager
        |> Process.whereis()
        |> tap(fn pid ->
          assert is_pid(pid)
        end)

      # Send rapid node events
      fake_nodes = [:node1@test, :node2@test, :node3@test]

      for node <- fake_nodes do
        send(manager_pid, {:nodeup, node, %{}})
        Process.sleep(5)
      end

      # Send some node down events
      for node <- Enum.take(fake_nodes, 2) do
        send(manager_pid, {:nodedown, node, %{}})
        Process.sleep(5)
      end

      # Wait for manager to process events
      Process.sleep(100)

      # Ring should be stable now
      current_ring = HashRing.current()
      assert current_ring.generation > original_ring.generation

      # Create a session and verify it works
      {:ok, session} =
        Conversation.start_session(%{
          initiator_id: "user:cluster:alice",
          peer_id: "user:cluster:bob"
        })

      slot = HashRing.slot_for_session(session.id)
      _ = ensure_slot!(slot)

      assert {:ok, _} =
               Gateway.append_message(session.id, %{
                 sender_id: session.initiator_id,
                 kind: "text",
                 content: %{text: "after-node-events"},
                 idempotency_key: "after-node-events"
               })

      :ok
    end
  end

  describe "erpc failure simulation" do
    test "router handles erpc timeouts gracefully" do
      {:ok, session} =
        Conversation.start_session(%{
          initiator_id: "user:cluster:alice",
          peer_id: "user:cluster:bob"
        })

      # Create a ring that assigns slot to a non-existent node
      fake_ring = HashRing.build(128, [:nonexistent@node])
      HashRing.put_current!(fake_ring)

      # Router should eventually timeout/fail gracefully
      start_time = System.monotonic_time(:millisecond)

      result =
        try do
          Gateway.append_message(session.id, %{
            sender_id: session.initiator_id,
            kind: "text",
            content: %{text: "should-timeout"},
            idempotency_key: "should-timeout"
          })
        catch
          :exit, reason -> {:exit, reason}
          :error, reason -> {:error, reason}
        end

      end_time = System.monotonic_time(:millisecond)
      duration = end_time - start_time

      # Should fail after retries (router has max 5 attempts with backoff)
      assert match?({:error, _}, result) or match?({:exit, _}, result)

      # Should not hang indefinitely
      assert duration < 10_000
    end

    test "await_persistence handles remote node failures" do
      {:ok, session} =
        Conversation.start_session(%{
          initiator_id: "user:cluster:alice",
          peer_id: "user:cluster:bob"
        })

      # Send message on local node first
      assert {:ok, message} =
               Gateway.append_message(session.id, %{
                 sender_id: session.initiator_id,
                 kind: "text",
                 content: %{text: "test-message"},
                 idempotency_key: "test-message"
               })

      # Now change ring to point to fake remote node
      fake_ring = HashRing.build(128, [:remote@node])
      HashRing.put_current!(fake_ring)

      # await_persistence should fail gracefully for remote node
      result =
        try do
          Router.await_persistence(session.id, message.id, 1000)
        catch
          :exit, reason -> {:exit, reason}
          :error, reason -> {:error, reason}
        end

      assert match?({:error, _}, result) or match?({:exit, _}, result)
    end
  end

  describe "split brain scenarios" do
    test "conflicting slot assignments resolve without data corruption" do
      {:ok, session} =
        Conversation.start_session(%{
          initiator_id: "user:cluster:alice",
          peer_id: "user:cluster:bob"
        })

      slot = HashRing.slot_for_session(session.id)

      # Start slot on "local" node
      local_pid = ensure_slot!(slot)

      # Send message to establish state
      assert {:ok, _msg1} =
               Gateway.append_message(session.id, %{
                 sender_id: session.initiator_id,
                 kind: "text",
                 content: %{text: "local-message"},
                 idempotency_key: "local-message"
               })

      # Simulate split brain: create ring with different assignments
      original_ring = HashRing.current()

      split_ring1 = %{
        original_ring
        | assignments: Map.put(original_ring.assignments, slot, Node.self())
      }

      split_ring2 = %{
        original_ring
        | assignments: Map.put(original_ring.assignments, slot, :other@node)
      }

      # Apply conflicting ring
      HashRing.put_current!(split_ring2)

      # Local slot should detect it's not the owner and drain
      GenServer.cast(local_pid, :rebalance)
      ref = Process.monitor(local_pid)
      assert_receive {:DOWN, ^ref, :process, ^local_pid, _}, 2000

      # Restore correct ring
      HashRing.put_current!(split_ring1)
      _ = ensure_slot!(slot)

      # Verify original message survived the split brain resolution
      messages = Gateway.replay_messages(session.id, limit: 10)
      texts = Enum.map(messages, & &1.content["text"])
      assert "local-message" in texts

      # Should be able to add new messages
      assert {:ok, _msg2} =
               Gateway.append_message(session.id, %{
                 sender_id: session.initiator_id,
                 kind: "text",
                 content: %{text: "post-split-brain"},
                 idempotency_key: "post-split-brain"
               })
    end
  end
end
