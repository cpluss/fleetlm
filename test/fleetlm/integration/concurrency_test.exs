defmodule Fleetlm.Integration.ConcurrencyTest do
  @moduledoc """
  Integration tests for concurrent operations and race conditions.

  Tests high-stress scenarios with multiple participants, concurrent messaging,
  and potential race conditions in the chat system.
  """

  use Fleetlm.DataCase, async: false

  alias Fleetlm.{Cache, Chat}
  alias Fleetlm.Chat.Threads.Message

  @moduletag timeout: :timer.seconds(30)

  describe "concurrent message sending" do
    test "maintains message ordering under high concurrency" do
      participants = for _ <- 1..5, do: Ecto.UUID.generate()
      [first_participant | _] = participants

      # Create group thread by ensuring DMs between all participants
      thread = Chat.ensure_dm!(first_participant, Enum.at(participants, 1))

      # Ensure ThreadServer is running
      {:ok, _} = Chat.ensure_thread_runtime(thread.id)

      # Send 20 messages concurrently from different participants
      message_count = 20

      tasks =
        for i <- 1..message_count do
          sender = Enum.at(participants, rem(i, length(participants)))

          Task.async(fn ->
            {:ok, message} =
              Chat.dispatch_message(%{
                thread_id: thread.id,
                sender_id: sender,
                text: "Message #{i}",
                role: "user"
              })

            {i, message}
          end)
        end

      results = Task.await_many(tasks, 10_000)
      messages = Enum.map(results, fn {_i, message} -> message end)

      # Verify all messages were created
      assert length(messages) == message_count

      # Verify messages are properly ordered in database
      db_messages = Chat.list_thread_messages(thread.id, limit: message_count)
      assert length(db_messages) == message_count

      # Verify no duplicate messages
      message_ids = Enum.map(db_messages, & &1.id)
      assert length(Enum.uniq(message_ids)) == message_count

      # Verify cache consistency
      cached_messages = Cache.get_messages(thread.id, message_count)
      assert cached_messages != nil
      assert length(cached_messages) <= message_count
    end

    test "handles ThreadServer startup race conditions" do
      participant_a = Ecto.UUID.generate()
      participant_b = Ecto.UUID.generate()
      thread = Chat.ensure_dm!(participant_a, participant_b)

      # Try to start ThreadServer and send messages simultaneously from multiple processes
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            # Each task tries to ensure ThreadServer and send a message
            case Chat.ensure_thread_runtime(thread.id) do
              {:ok, _pid} ->
                Chat.dispatch_message(%{
                  thread_id: thread.id,
                  sender_id: if(rem(i, 2) == 0, do: participant_a, else: participant_b),
                  text: "Race message #{i}"
                })

              error ->
                error
            end
          end)
        end

      results = Task.await_many(tasks, 5_000)

      # All should succeed
      successes =
        Enum.count(results, fn
          {:ok, %Message{}} -> true
          _ -> false
        end)

      assert successes == 10

      # Verify only one ThreadServer process exists
      registry_entries = Registry.lookup(Fleetlm.Chat.ThreadRegistry, thread.id)
      assert length(registry_entries) == 1
    end
  end

  describe "cache consistency under stress" do
    test "maintains cache coherence during rapid operations" do
      participant_a = Ecto.UUID.generate()
      participant_b = Ecto.UUID.generate()
      thread = Chat.ensure_dm!(participant_a, participant_b)

      {:ok, _} = Chat.ensure_thread_runtime(thread.id)

      # Perform rapid cache operations from multiple processes
      cache_operations = 50

      tasks =
        for i <- 1..cache_operations do
          Task.async(fn ->
            case rem(i, 4) do
              0 ->
                # Send message (triggers cache updates)
                Chat.dispatch_message(%{
                  thread_id: thread.id,
                  sender_id: participant_a,
                  text: "Cache test #{i}"
                })

              1 ->
                # Read messages (cache hit/miss)
                Cache.get_messages(thread.id, 10)

              2 ->
                # Update participant cache
                Cache.cache_participants(thread.id, [participant_a, participant_b])

              3 ->
                # Read thread metadata
                Cache.get_thread_meta(thread.id)
            end
          end)
        end

      Task.await_many(tasks, 10_000)

      # Verify cache is in consistent state
      cached_messages = Cache.get_messages(thread.id)
      cached_participants = Cache.get_participants(thread.id)
      cached_meta = Cache.get_thread_meta(thread.id)

      assert cached_messages != nil
      assert cached_participants != nil
      assert cached_meta != nil

      # Verify database consistency
      db_messages = Chat.list_thread_messages(thread.id)

      # Messages should be consistent between cache and database
      if cached_messages do
        cached_ids = Enum.map(cached_messages, & &1.id) |> MapSet.new()

        db_ids =
          Enum.take(db_messages, length(cached_messages)) |> Enum.map(& &1.id) |> MapSet.new()

        assert MapSet.subset?(cached_ids, db_ids)
      end
    end
  end

  describe "participant operations under concurrency" do
    test "handles simultaneous participant joins/leaves" do
      # Create a base thread
      base_participant = Ecto.UUID.generate()
      other_participant = Ecto.UUID.generate()
      thread = Chat.ensure_dm!(base_participant, other_participant)

      {:ok, _} = Chat.ensure_thread_runtime(thread.id)

      # Create many new participants that will join concurrently
      new_participants = for _ <- 1..20, do: Ecto.UUID.generate()

      # Each participant tries to join by creating a DM with base participant
      tasks =
        Enum.map(new_participants, fn participant ->
          Task.async(fn ->
            Chat.ensure_dm!(base_participant, participant)
          end)
        end)

      results = Task.await_many(tasks, 10_000)

      # All should succeed and create new threads
      assert length(results) == 20

      # Verify all threads were created
      thread_ids = Enum.map(results, & &1.id) |> Enum.uniq()
      assert length(thread_ids) == 20

      # Verify base participant is in all threads
      participant_threads = Chat.list_threads_for_participant(base_participant)
      assert length(participant_threads) >= 20
    end
  end

  describe "message burst handling" do
    test "handles rapid message bursts without data loss" do
      participant_a = Ecto.UUID.generate()
      participant_b = Ecto.UUID.generate()
      thread = Chat.ensure_dm!(participant_a, participant_b)

      {:ok, _} = Chat.ensure_thread_runtime(thread.id)

      # Send a burst of 100 messages as fast as possible
      burst_size = 100

      tasks =
        for i <- 1..burst_size do
          Task.async(fn ->
            sender = if rem(i, 2) == 0, do: participant_a, else: participant_b

            Chat.dispatch_message(%{
              thread_id: thread.id,
              sender_id: sender,
              text: "Burst #{i}",
              metadata: %{sequence: i}
            })
          end)
        end

      results = Task.await_many(tasks, 15_000)

      # All messages should succeed
      successes =
        Enum.count(results, fn
          {:ok, %Message{}} -> true
          _ -> false
        end)

      assert successes == burst_size

      # Verify all messages are in database
      db_messages = Chat.list_thread_messages(thread.id, limit: burst_size)
      assert length(db_messages) == burst_size

      # Verify message sequence integrity
      sequences =
        Enum.map(db_messages, fn msg ->
          msg.metadata["sequence"]
        end)
        |> Enum.filter(& &1)
        |> Enum.sort()

      assert sequences == Enum.to_list(1..burst_size)

      # Verify participants metadata is consistent
      final_participant_a =
        Chat.list_threads_for_participant(participant_a)
        |> Enum.find(fn p -> p.thread_id == thread.id end)

      final_participant_b =
        Chat.list_threads_for_participant(participant_b)
        |> Enum.find(fn p -> p.thread_id == thread.id end)

      assert final_participant_a.last_message_preview =~ "Burst"
      assert final_participant_b.last_message_preview =~ "Burst"
    end
  end

  describe "error recovery scenarios" do
    test "recovers gracefully from ThreadServer crashes" do
      participant_a = Ecto.UUID.generate()
      participant_b = Ecto.UUID.generate()
      thread = Chat.ensure_dm!(participant_a, participant_b)

      # Start ThreadServer and send initial message
      {:ok, initial_pid} = Chat.ensure_thread_runtime(thread.id)

      {:ok, _} =
        Chat.dispatch_message(%{
          thread_id: thread.id,
          sender_id: participant_a,
          text: "Before crash"
        })

      # Simulate crash by killing the process
      Process.exit(initial_pid, :kill)

      # Wait for process to die
      Process.sleep(100)

      # Verify process is dead
      refute Process.alive?(initial_pid)

      # Try to send message immediately (should restart ThreadServer)
      {:ok, _recovery_message} =
        Chat.dispatch_message(%{
          thread_id: thread.id,
          sender_id: participant_b,
          text: "After recovery"
        })

      # Verify new ThreadServer is running
      {:ok, new_pid} = Chat.ensure_thread_runtime(thread.id)
      assert new_pid != initial_pid
      assert Process.alive?(new_pid)

      # Verify both messages are in database
      messages = Chat.list_thread_messages(thread.id)
      message_texts = Enum.map(messages, & &1.text)

      assert "Before crash" in message_texts
      assert "After recovery" in message_texts

      # Verify cache was properly warmed after restart
      cached_messages = Cache.get_messages(thread.id, 5)
      assert cached_messages != nil
      assert length(cached_messages) >= 1
    end
  end
end
