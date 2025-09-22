defmodule Fleetlm.Integration.MultiParticipantTest do
  @moduledoc """
  Integration tests for multi-participant scenarios, agent roles, and complex chat flows.
  """

  use FleetlmWeb.ChannelCase, async: false

  alias Fleetlm.{Cache, Chat}
  alias Fleetlm.Chat.Threads.Message

  describe "agent role interactions" do
    test "agent and human conversation flow" do
      human_id = Ecto.UUID.generate()
      agent_id = Ecto.UUID.generate()

      # Create DM with explicit roles
      thread = Chat.ensure_dm!(human_id, agent_id, roles: {"user", "agent"})

      # Verify participants have correct roles
      participants = Chat.list_threads_for_participant(human_id)
      human_participation = Enum.find(participants, &(&1.thread_id == thread.id))
      assert human_participation.role == "user"

      agent_participants = Chat.list_threads_for_participant(agent_id)
      agent_participation = Enum.find(agent_participants, &(&1.thread_id == thread.id))
      assert agent_participation.role == "agent"

      # Human sends message
      {:ok, human_message} =
        Chat.dispatch_message(%{
          thread_id: thread.id,
          sender_id: human_id,
          text: "Hello, I need help with something",
          role: "user"
        })

      assert human_message.role == "user"

      # Agent responds
      {:ok, agent_message} =
        Chat.dispatch_message(%{
          thread_id: thread.id,
          sender_id: agent_id,
          text: "Hello! I'd be happy to help. What do you need assistance with?",
          role: "agent"
        })

      assert agent_message.role == "agent"

      # Verify conversation flow in database
      messages = Chat.list_thread_messages(thread.id)
      assert length(messages) == 2

      [latest, first] = messages
      assert latest.id == agent_message.id
      assert latest.role == "agent"
      assert first.id == human_message.id
      assert first.role == "user"

      # Verify cache maintains role information
      cached_messages = Cache.get_messages(thread.id)
      assert cached_messages != nil
      assert length(cached_messages) == 2

      cached_roles = Enum.map(cached_messages, & &1.role)
      assert "user" in cached_roles
      assert "agent" in cached_roles
    end

    test "system messages in conversation" do
      human_id = Ecto.UUID.generate()
      agent_id = Ecto.UUID.generate()
      thread = Chat.ensure_dm!(human_id, agent_id)

      # System message (e.g., conversation started) - Use a special system participant ID
      system_participant = Ecto.UUID.generate()

      {:ok, system_msg} =
        Chat.dispatch_message(%{
          thread_id: thread.id,
          sender_id: system_participant,
          text: "Conversation started",
          role: "system",
          kind: "event"
        })

      # Human message
      {:ok, human_msg} =
        Chat.dispatch_message(%{
          thread_id: thread.id,
          sender_id: human_id,
          text: "Hello",
          role: "user"
        })

      # Agent response
      {:ok, agent_msg} =
        Chat.dispatch_message(%{
          thread_id: thread.id,
          sender_id: agent_id,
          text: "Hi there!",
          role: "agent"
        })

      # Another system message (e.g., status update)
      {:ok, status_msg} =
        Chat.dispatch_message(%{
          thread_id: thread.id,
          sender_id: system_participant,
          text: "Agent typing...",
          role: "system",
          kind: "event"
        })

      messages = Chat.list_thread_messages(thread.id)
      assert length(messages) == 4

      # Verify message types and ordering
      [latest, third, second, first] = messages

      assert first.id == system_msg.id
      assert first.role == "system"
      assert first.kind == "event"

      assert second.id == human_msg.id
      assert second.role == "user"

      assert third.id == agent_msg.id
      assert third.role == "agent"

      assert latest.id == status_msg.id
      assert latest.role == "system"
    end
  end

  describe "group conversation simulation" do
    test "multiple users in extended conversation" do
      # Simulate a group by creating multiple DM threads with a central participant
      coordinator = Ecto.UUID.generate()
      participants = for i <- 1..5, do: {"user_#{i}", Ecto.UUID.generate()}

      # Create individual DM threads
      threads =
        for {_name, participant_id} <- participants do
          Chat.ensure_dm!(coordinator, participant_id)
        end

      # Start conversation in all threads
      for {thread, {name, participant_id}} <- Enum.zip(threads, participants) do
        {:ok, _} =
          Chat.dispatch_message(%{
            thread_id: thread.id,
            sender_id: participant_id,
            text: "Hello from #{name}!"
          })

        # Coordinator responds
        {:ok, _} =
          Chat.dispatch_message(%{
            thread_id: thread.id,
            sender_id: coordinator,
            text: "Hello #{name}, welcome to the group!"
          })
      end

      # Verify coordinator has all conversations
      coordinator_threads = Chat.list_threads_for_participant(coordinator)
      assert length(coordinator_threads) >= 5

      # Each thread should have 2 messages
      for thread <- threads do
        messages = Chat.list_thread_messages(thread.id)
        assert length(messages) == 2
      end

      # Verify each participant thread has correct metadata
      for {thread, {_name, participant_id}} <- Enum.zip(threads, participants) do
        participant_data = Chat.list_threads_for_participant(participant_id)
        thread_data = Enum.find(participant_data, &(&1.thread_id == thread.id))

        assert thread_data.last_message_preview =~ "welcome"
      end
    end

    test "broadcast-style messaging simulation" do
      broadcaster = Ecto.UUID.generate()
      subscribers = for _i <- 1..10, do: Ecto.UUID.generate()

      # Create DM threads with all subscribers
      threads =
        for subscriber <- subscribers do
          Chat.ensure_dm!(broadcaster, subscriber)
        end

      # Broadcaster sends same message to all threads (simulating broadcast)
      broadcast_text = "Important announcement: System maintenance tonight at 10 PM"

      broadcast_tasks =
        for thread <- threads do
          Task.async(fn ->
            Chat.dispatch_message(%{
              thread_id: thread.id,
              sender_id: broadcaster,
              text: broadcast_text,
              kind: "broadcast"
            })
          end)
        end

      broadcast_results = Task.await_many(broadcast_tasks, 5000)

      # All broadcasts should succeed
      assert length(broadcast_results) == 10

      assert Enum.all?(broadcast_results, fn
               {:ok, %Message{}} -> true
               _ -> false
             end)

      # Verify all subscribers received the message
      for subscriber <- subscribers do
        subscriber_threads = Chat.list_threads_for_participant(subscriber)

        broadcast_thread =
          Enum.find(subscriber_threads, fn thread_data ->
            thread_data.last_message_preview == broadcast_text
          end)

        assert broadcast_thread != nil
      end

      # Verify broadcaster shows all outgoing messages
      broadcaster_threads = Chat.list_threads_for_participant(broadcaster)

      broadcast_threads =
        Enum.filter(broadcaster_threads, fn thread_data ->
          thread_data.last_message_preview == broadcast_text
        end)

      assert length(broadcast_threads) == 10
    end
  end

  describe "real-time channel integration" do
    test "multi-participant channel synchronization" do
      participants = for i <- 1..3, do: {"user_#{i}", Ecto.UUID.generate()}
      [{"user_1", user1_id}, {"user_2", user2_id}, {"user_3", _user3_id}] = participants

      # Create thread between user1 and user2
      thread = Chat.ensure_dm!(user1_id, user2_id)

      # All participants join channels
      _participant_sockets =
        for {_name, participant_id} <- participants do
          socket = socket(FleetlmWeb.UserSocket, nil, %{participant_id: participant_id})

          {:ok, _reply, p_socket} =
            subscribe_and_join(
              socket,
              FleetlmWeb.ParticipantChannel,
              "participant:#{participant_id}"
            )

          {participant_id, p_socket}
        end

      # User1 and User2 join thread channel
      thread_sockets =
        for participant_id <- [user1_id, user2_id] do
          socket = socket(FleetlmWeb.UserSocket, nil, %{participant_id: participant_id})

          {:ok, _reply, t_socket} =
            subscribe_and_join(socket, FleetlmWeb.ThreadChannel, "thread:#{thread.id}")

          {participant_id, t_socket}
        end

      # User1 sends message
      {user1_id, user1_thread_socket} =
        Enum.find(thread_sockets, fn {id, _} -> id == user1_id end)

      ref =
        push(user1_thread_socket, "message:new", %{
          "text" => "Hello from user1!",
          "role" => "user"
        })

      assert_reply ref, :ok, %{"text" => "Hello from user1!", "sender_id" => ^user1_id}

      # Both thread participants should receive the message
      assert_push "message", %{"text" => "Hello from user1!", "sender_id" => ^user1_id}
      assert_push "message", %{"text" => "Hello from user1!", "sender_id" => ^user1_id}

      # Participant channels should receive tick updates
      # (We need to wait a bit for the tick interval)
      Process.sleep(200)

      assert_push "tick", %{"updates" => updates}, 500

      # At least one participant in the thread should get updates
      participant_ids = Enum.map(updates, & &1["participant_id"])
      assert user1_id in participant_ids or user2_id in participant_ids

      # User3 (not in thread) should not receive thread-specific updates for this thread
      # But might receive other updates, so we can't assert absence directly
    end

    test "participant presence across multiple threads" do
      central_user = Ecto.UUID.generate()
      other_users = for _i <- 1..3, do: Ecto.UUID.generate()

      # Create threads between central user and each other user
      threads =
        for other_user <- other_users do
          Chat.ensure_dm!(central_user, other_user)
        end

      # Central user joins participant channel
      central_socket = socket(FleetlmWeb.UserSocket, nil, %{participant_id: central_user})

      {:ok, join_reply, _central_p_socket} =
        subscribe_and_join(
          central_socket,
          FleetlmWeb.ParticipantChannel,
          "participant:#{central_user}"
        )

      # Should see all threads in join reply
      assert %{"threads" => threads_data} = join_reply
      assert length(threads_data) >= 3

      thread_ids = Enum.map(threads_data, & &1["thread_id"])
      expected_thread_ids = Enum.map(threads, & &1.id)

      for expected_id <- expected_thread_ids do
        assert expected_id in thread_ids
      end

      # Send messages from other users concurrently
      message_tasks =
        for {other_user, thread} <- Enum.zip(other_users, threads) do
          Task.async(fn ->
            Chat.dispatch_message(%{
              thread_id: thread.id,
              sender_id: other_user,
              text: "Message from #{other_user}"
            })
          end)
        end

      Task.await_many(message_tasks, 2000)

      # Central user should receive tick updates for all threads
      Process.sleep(200)

      # Collect multiple tick updates
      updates = collect_all_tick_updates(3000)

      # Should have updates for all 3 threads
      updated_thread_ids =
        updates
        |> Enum.map(& &1["thread_id"])
        |> Enum.uniq()

      assert length(updated_thread_ids) >= 3

      for expected_id <- expected_thread_ids do
        assert expected_id in updated_thread_ids
      end
    end
  end

  describe "performance under multi-participant load" do
    test "handles many concurrent participants efficiently" do
      # Create a scenario with many participants all interacting
      participant_count = 20
      participants = for _ <- 1..participant_count, do: Ecto.UUID.generate()

      # Create hub-and-spoke pattern (everyone connected to first participant)
      [hub | spokes] = participants

      # Create all threads
      threads =
        for spoke <- spokes do
          Chat.ensure_dm!(hub, spoke)
        end

      # All participants send messages simultaneously
      message_tasks =
        for {spoke, thread} <- Enum.zip(spokes, threads) do
          Task.async(fn ->
            start_time = System.monotonic_time(:millisecond)

            {:ok, message} =
              Chat.dispatch_message(%{
                thread_id: thread.id,
                sender_id: spoke,
                text: "Message from #{spoke}"
              })

            end_time = System.monotonic_time(:millisecond)
            {message, end_time - start_time}
          end)
        end

      results = Task.await_many(message_tasks, 10_000)

      # All should succeed
      assert length(results) == participant_count - 1

      # Measure performance
      durations = Enum.map(results, fn {_message, duration} -> duration end)
      avg_duration = Enum.sum(durations) / length(durations)
      max_duration = Enum.max(durations)

      # Performance assertions (should be reasonable for development)
      # Average under 500ms
      assert avg_duration < 500
      # Max under 2 seconds
      assert max_duration < 2000

      # Verify hub participant has all conversations
      hub_threads = Chat.list_threads_for_participant(hub)
      assert length(hub_threads) >= participant_count - 1

      # Verify cache efficiency - hub's threads should be cached
      cached_count =
        Enum.count(hub_threads, fn thread_data ->
          Cache.get_messages(thread_data.thread_id) != nil
        end)

      # At least some threads should be cached
      assert cached_count > 0
    end
  end

  # Helper function to collect all tick updates within a time window
  defp collect_all_tick_updates(timeout) do
    collect_all_tick_updates(timeout, System.monotonic_time(:millisecond), [])
  end

  defp collect_all_tick_updates(timeout, start_time, acc) do
    current_time = System.monotonic_time(:millisecond)
    remaining = timeout - (current_time - start_time)

    if remaining <= 0 do
      acc
    else
      receive do
        %Phoenix.Socket.Message{event: "tick", payload: %{"updates" => updates}} ->
          collect_all_tick_updates(timeout, start_time, acc ++ updates)
      after
        min(remaining, 100) ->
          collect_all_tick_updates(timeout, start_time, acc)
      end
    end
  end
end
