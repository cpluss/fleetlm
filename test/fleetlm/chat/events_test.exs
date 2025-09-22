defmodule Fleetlm.Chat.EventsTest do
  use FleetlmWeb.ChannelCase
  import ExUnit.CaptureLog

  alias Fleetlm.Chat
  alias Fleetlm.Chat.Events

  describe "Events.broadcast_dm_message/1" do
    test "broadcasts message to dm channel and participant metadata" do
      user_a = "user:alice"
      user_b = "user:bob"
      dm_key = Chat.generate_dm_key(user_a, user_b)

      # Subscribe to all relevant channels BEFORE creating message
      Phoenix.PubSub.subscribe(Fleetlm.PubSub, "dm:" <> dm_key)
      Phoenix.PubSub.subscribe(Fleetlm.PubSub, "participant:" <> user_a)
      Phoenix.PubSub.subscribe(Fleetlm.PubSub, "participant:" <> user_b)

      # Create a DM message (this will auto-trigger the domain event)
      {:ok, message} = Chat.send_dm_message(user_a, user_b, "Hello Bob!")

      # Check that we received the messages
      assert_receive {:dm_message, received_message}
      assert received_message.id == message.id
      assert received_message.text == "Hello Bob!"

      # Check participant A gets metadata
      assert_receive {:dm_activity, metadata_a}
      assert metadata_a[:dm_key] == message.dm_key
      assert metadata_a[:sender_id] == user_a
      assert metadata_a[:last_message_text] == "Hello Bob!"
      assert metadata_a[:other_participant_id] == user_b

      # Check participant B gets metadata
      assert_receive {:dm_activity, metadata_b}
      assert metadata_b[:dm_key] == message.dm_key
      assert metadata_b[:sender_id] == user_a
      assert metadata_b[:last_message_text] == "Hello Bob!"
      assert metadata_b[:other_participant_id] == user_a
    end
  end

  describe "Events.broadcast_dm_created/4" do
    test "notifies both participants about new DM without message" do
      user_a = "user:alice"
      user_c = "user:charlie"

      # Subscribe to participant channels
      Phoenix.PubSub.subscribe(Fleetlm.PubSub, "participant:" <> user_a)
      Phoenix.PubSub.subscribe(Fleetlm.PubSub, "participant:" <> user_c)

      dm_key = Chat.generate_dm_key(user_a, user_c)

      # Broadcast DM creation event
      Events.broadcast_dm_created(dm_key, user_a, user_c)

      # Check that both participants get notified
      assert_receive {:dm_activity, metadata_a}
      assert metadata_a[:dm_key] == dm_key
      assert metadata_a[:sender_id] == user_a
      assert metadata_a[:last_message_text] == nil
      assert metadata_a[:other_participant_id] == user_c

      assert_receive {:dm_activity, metadata_c}
      assert metadata_c[:dm_key] == dm_key
      assert metadata_c[:sender_id] == user_a
      assert metadata_c[:last_message_text] == nil
      assert metadata_c[:other_participant_id] == user_a
    end

    test "notifies both participants about new DM with initial message" do
      user_a = "user:alice"
      user_d = "user:david"

      # Create initial message
      {:ok, message} = Chat.send_dm_message(user_a, user_d, "Hey David!")

      # Subscribe to participant channels
      Phoenix.PubSub.subscribe(Fleetlm.PubSub, "participant:" <> user_a)
      Phoenix.PubSub.subscribe(Fleetlm.PubSub, "participant:" <> user_d)

      dm_key = message.dm_key

      # Clear any messages from the send_dm_message call
      :timer.sleep(10)
      flush()

      # Broadcast DM creation event with initial message
      Events.broadcast_dm_created(dm_key, user_a, user_d, message)

      # Check notifications
      assert_receive {:dm_activity, metadata_a}
      assert metadata_a[:dm_key] == dm_key
      assert metadata_a[:sender_id] == user_a
      assert metadata_a[:last_message_text] == "Hey David!"
      assert metadata_a[:other_participant_id] == user_d

      assert_receive {:dm_activity, metadata_d}
      assert metadata_d[:dm_key] == dm_key
      assert metadata_d[:sender_id] == user_a
      assert metadata_d[:last_message_text] == "Hey David!"
      assert metadata_d[:other_participant_id] == user_a
    end
  end

  describe "Events.broadcast_broadcast_message/1" do
    test "broadcasts message to broadcast channel" do
      user_a = "user:alice"

      # Subscribe to broadcast channel
      Phoenix.PubSub.subscribe(Fleetlm.PubSub, "broadcast")

      # Send broadcast message (should auto-trigger event)
      {:ok, message} = Chat.send_broadcast_message(user_a, "Hello everyone!")

      # Check that we received the broadcast
      assert_receive {:broadcast_message, received_message}
      assert received_message.id == message.id
      assert received_message.text == "Hello everyone!"
      assert received_message.sender_id == user_a
    end
  end

  describe "error handling" do
    test "handles invalid dm_key format gracefully" do
      # This should log an error but not crash
      log_output = capture_log(fn ->
        # Create a fake message with invalid dm_key
        fake_message = %{
          dm_key: "invalid-format",
          created_at: DateTime.utc_now(),
          text: "test",
          sender_id: "user:test"
        }

        Events.broadcast_dm_message(fake_message)
      end)

      assert log_output =~ "Invalid dm_key format for broadcasting: invalid-format"
    end
  end

  # Helper to clear message queue
  defp flush do
    receive do
      _ -> flush()
    after
      0 -> :ok
    end
  end
end