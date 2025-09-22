defmodule Fleetlm.Integration.EdgeCasesTest do
  @moduledoc """
  Integration tests for edge cases, malformed data, and boundary conditions.
  """

  use Fleetlm.DataCase, async: false

  alias Fleetlm.{Cache, Chat}
  alias Fleetlm.Chat.Threads.Message

  describe "message content edge cases" do
    test "handles very long messages" do
      participant_a = Ecto.UUID.generate()
      participant_b = Ecto.UUID.generate()
      thread = Chat.ensure_dm!(participant_a, participant_b)

      # Create a 10KB message
      very_long_text = String.duplicate("A", 10_000)

      {:ok, message} =
        Chat.dispatch_message(%{
          thread_id: thread.id,
          sender_id: participant_a,
          text: very_long_text
        })

      assert String.length(message.text) == 10_000

      # Verify it's cached properly
      cached_messages = Cache.get_messages(thread.id, 1)
      assert cached_messages != nil
      assert length(cached_messages) == 1
      assert String.length(hd(cached_messages).text) == 10_000
    end

    test "handles unicode and emoji content" do
      participant_a = Ecto.UUID.generate()
      participant_b = Ecto.UUID.generate()
      thread = Chat.ensure_dm!(participant_a, participant_b)

      unicode_messages = [
        "Hello 世界! 🌍",
        "Emoji test: 🚀🔥💯👾🎉",
        "Math symbols: ∑∏∂∆∇∞",
        "Arabic: مرحبا بالعالم",
        "Chinese: 你好世界",
        "Japanese: こんにちは世界",
        "Russian: Привет мир",
        "Symbols: ©®™℠℗"
      ]

      _messages =
        for {text, i} <- Enum.with_index(unicode_messages) do
          {:ok, message} =
            Chat.dispatch_message(%{
              thread_id: thread.id,
              sender_id: if(rem(i, 2) == 0, do: participant_a, else: participant_b),
              text: text
            })

          message
        end

      # Verify all messages were stored correctly
      db_messages = Chat.list_thread_messages(thread.id)
      db_texts = Enum.map(db_messages, & &1.text)

      for original_text <- unicode_messages do
        assert original_text in db_texts
      end

      # Verify cache handles unicode correctly
      cached_messages = Cache.get_messages(thread.id, length(unicode_messages))
      assert cached_messages != nil
      assert length(cached_messages) == length(unicode_messages)
    end

    test "handles empty and whitespace-only messages" do
      participant_a = Ecto.UUID.generate()
      participant_b = Ecto.UUID.generate()
      thread = Chat.ensure_dm!(participant_a, participant_b)

      edge_case_texts = ["   ", "\n\n\n", "\t\t", " \n \t "]

      for text <- edge_case_texts do
        {:ok, message} =
          Chat.dispatch_message(%{
            thread_id: thread.id,
            sender_id: participant_a,
            text: text
          })

        # Whitespace may be normalized to nil by the system
        assert message.text in [text, nil]
      end

      # Test empty string separately (may be converted to nil)
      {:ok, empty_message} =
        Chat.dispatch_message(%{
          thread_id: thread.id,
          sender_id: participant_a,
          text: ""
        })

      # Empty string might be stored as nil
      assert empty_message.text in ["", nil]

      # Verify all messages were stored
      db_messages = Chat.list_thread_messages(thread.id)
      assert length(db_messages) == length(edge_case_texts) + 1
    end
  end

  describe "malformed data handling" do
    test "handles missing required fields gracefully" do
      participant_a = Ecto.UUID.generate()
      participant_b = Ecto.UUID.generate()
      thread = Chat.ensure_dm!(participant_a, participant_b)

      # Missing sender_id
      assert {:error, :validation, _reason} =
               Chat.send_message(%{
                 thread_id: thread.id,
                 text: "missing sender"
               })

      # Missing thread_id
      assert {:error, :validation, _reason} =
               Chat.send_message(%{
                 sender_id: participant_a,
                 text: "missing thread"
               })

      # Invalid thread_id
      assert {:error, :thread, :not_found} =
               Chat.send_message(%{
                 thread_id: Ecto.UUID.generate(),
                 sender_id: participant_a,
                 text: "invalid thread"
               })
    end

    test "handles invalid metadata gracefully" do
      participant_a = Ecto.UUID.generate()
      participant_b = Ecto.UUID.generate()
      thread = Chat.ensure_dm!(participant_a, participant_b)

      # Very large metadata
      large_metadata = %{
        "data" => String.duplicate("X", 5000),
        "numbers" => Enum.to_list(1..1000),
        "nested" => %{
          "deep" => %{
            "structure" => %{
              "value" => "test"
            }
          }
        }
      }

      {:ok, message} =
        Chat.dispatch_message(%{
          thread_id: thread.id,
          sender_id: participant_a,
          text: "metadata test",
          metadata: large_metadata
        })

      assert message.metadata["data"] == String.duplicate("X", 5000)
      assert length(message.metadata["numbers"]) == 1000

      # Verify it can be retrieved
      db_message = Repo.get!(Message, message.id)
      assert db_message.metadata["nested"]["deep"]["structure"]["value"] == "test"
    end

    test "handles invalid roles and kinds" do
      participant_a = Ecto.UUID.generate()
      participant_b = Ecto.UUID.generate()
      thread = Chat.ensure_dm!(participant_a, participant_b)

      # Valid roles should work
      valid_roles = ["user", "agent", "system"]

      for role <- valid_roles do
        {:ok, message} =
          Chat.dispatch_message(%{
            thread_id: thread.id,
            sender_id: participant_a,
            text: "role test",
            role: role
          })

        assert message.role == role
      end

      # Invalid role should be rejected by schema validation
      # (The Chat.send_message would fail at changeset validation)
      assert {:error, :message, changeset} =
               Chat.send_message(%{
                 thread_id: thread.id,
                 sender_id: participant_a,
                 text: "invalid role",
                 role: "invalid_role"
               })

      assert changeset.errors[:role] != nil
    end
  end

  describe "resource limits and boundaries" do
    test "handles maximum participant count gracefully" do
      base_participant = Ecto.UUID.generate()

      # Test with a reasonable number of participants (50)
      participants = for _ <- 1..50, do: Ecto.UUID.generate()

      # Create threads with all participants
      threads =
        for participant <- participants do
          Chat.ensure_dm!(base_participant, participant)
        end

      assert length(threads) == 50
      assert length(Enum.uniq_by(threads, & &1.id)) == 50

      # Verify base participant is in all threads
      participant_threads = Chat.list_threads_for_participant(base_participant)
      assert length(participant_threads) >= 50
    end

    test "handles message pagination at boundaries" do
      participant_a = Ecto.UUID.generate()
      participant_b = Ecto.UUID.generate()
      thread = Chat.ensure_dm!(participant_a, participant_b)

      # Create exactly 100 messages
      message_count = 100

      for i <- 1..message_count do
        {:ok, _} =
          Chat.dispatch_message(%{
            thread_id: thread.id,
            sender_id: if(rem(i, 2) == 0, do: participant_a, else: participant_b),
            text: "Message #{i}"
          })
      end

      # Test various limit scenarios
      test_cases = [
        # Single message
        {1, 1},
        # Standard page
        {50, 50},
        # Just under 100
        {99, 99},
        # Exactly 100
        {100, 100},
        # Over limit (should cap at 100)
        {101, 100},
        # Way over limit
        {200, 100}
      ]

      for {requested_limit, expected_count} <- test_cases do
        messages = Chat.list_thread_messages(thread.id, limit: requested_limit)
        assert length(messages) == expected_count
      end

      # Test pagination with cursor
      all_messages = Chat.list_thread_messages(thread.id, limit: message_count)
      # 50th message (0-indexed)
      middle_message = Enum.at(all_messages, 49)

      before_messages =
        Chat.list_thread_messages(thread.id,
          before: %{created_at: middle_message.created_at, id: middle_message.id},
          limit: 50
        )

      assert length(before_messages) == 50

      # Verify no overlap
      before_ids = Enum.map(before_messages, & &1.id) |> MapSet.new()
      refute MapSet.member?(before_ids, middle_message.id)
    end
  end

  describe "cache behavior under stress" do
    test "handles cache eviction gracefully" do
      participant_a = Ecto.UUID.generate()
      _participant_b = Ecto.UUID.generate()

      # Create multiple threads to fill cache
      threads =
        for i <- 1..20 do
          other_participant = Ecto.UUID.generate()
          thread = Chat.ensure_dm!(participant_a, other_participant)

          # Send messages to each thread
          for j <- 1..10 do
            {:ok, _} =
              Chat.dispatch_message(%{
                thread_id: thread.id,
                sender_id: participant_a,
                text: "Thread #{i}, Message #{j}"
              })
          end

          thread
        end

      # Verify all threads have cached data
      for thread <- threads do
        cached_messages = Cache.get_messages(thread.id)
        assert cached_messages != nil
        assert length(cached_messages) >= 1
      end

      # Access pattern should maintain frequently used caches
      frequently_used_thread = hd(threads)

      for _ <- 1..50 do
        Cache.get_messages(frequently_used_thread.id)
      end

      # This frequently accessed thread should still be cached
      assert Cache.get_messages(frequently_used_thread.id) != nil
    end

    test "maintains cache consistency during invalidation storms" do
      participant_a = Ecto.UUID.generate()
      participant_b = Ecto.UUID.generate()
      thread = Chat.ensure_dm!(participant_a, participant_b)

      # Send initial message to populate cache
      {:ok, _} =
        Chat.dispatch_message(%{
          thread_id: thread.id,
          sender_id: participant_a,
          text: "Initial message"
        })

      # Perform many rapid invalidations and reads
      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            case rem(i, 3) do
              0 ->
                Cache.invalidate_messages(thread.id)
                Cache.invalidate_participants(thread.id)
                Cache.invalidate_thread_meta(thread.id)
                :invalidated

              1 ->
                Cache.get_messages(thread.id)

              2 ->
                Chat.dispatch_message(%{
                  thread_id: thread.id,
                  sender_id: if(rem(i, 2) == 0, do: participant_a, else: participant_b),
                  text: "Invalidation test #{i}"
                })
            end
          end)
        end

      results = Task.await_many(tasks, 10_000)

      # System should remain stable
      assert length(results) == 50

      # Final state should be consistent
      final_messages = Chat.list_thread_messages(thread.id)
      cached_messages = Cache.get_messages(thread.id)

      # Should have initial message plus some from the test
      assert length(final_messages) >= 1

      # Cache should be in a valid state (either populated or empty, not corrupted)
      if cached_messages do
        cached_ids = Enum.map(cached_messages, & &1.id) |> MapSet.new()

        db_ids =
          Enum.take(final_messages, length(cached_messages)) |> Enum.map(& &1.id) |> MapSet.new()

        assert MapSet.subset?(cached_ids, db_ids)
      end
    end
  end
end
