defmodule Fleetlm.ChatTest do
  use Fleetlm.DataCase

  alias Fleetlm.Chat

  describe "DM messaging" do
    test "send_dm_message/4 creates a DM message" do
      sender_id = "user:alice"
      recipient_id = "user:bob"

      assert {:ok, message} = Chat.send_dm_message(sender_id, recipient_id, "Hello!")

      assert message.sender_id == sender_id
      assert message.recipient_id == recipient_id
      assert message.text == "Hello!"
      assert message.shard_key >= 0
    end

    test "send_dm_message/4 fails when sender and recipient are the same" do
      user_id = "user:alice"

      assert {:error, changeset} = Chat.send_dm_message(user_id, user_id, "Self talk")
      assert changeset.errors[:recipient_id] == {"cannot be the same as sender", []}
    end

    test "get_dm_conversation/3 returns messages between two users" do
      user_a = "user:alice"
      user_b = "user:bob"
      user_c = "user:charlie"

      # Create messages
      {:ok, _msg1} = Chat.send_dm_message(user_a, user_b, "Message 1")
      {:ok, _msg2} = Chat.send_dm_message(user_b, user_a, "Message 2")
      {:ok, _msg3} = Chat.send_dm_message(user_a, user_c, "Different conversation")

      messages = Chat.get_dm_conversation(user_a, user_b)

      assert length(messages) == 2
      assert Enum.any?(messages, &(&1.text == "Message 1"))
      assert Enum.any?(messages, &(&1.text == "Message 2"))
      refute Enum.any?(messages, &(&1.text == "Different conversation"))
    end

    test "get_dm_threads_for_user/2 returns user's DM threads" do
      user_a = "user:alice"
      user_b = "user:bob"
      user_c = "user:charlie"

      {:ok, _} = Chat.send_dm_message(user_a, user_b, "Hello B")
      {:ok, _} = Chat.send_dm_message(user_a, user_c, "Hello C")

      threads = Chat.get_dm_threads_for_user(user_a)

      assert length(threads) == 2

      # Check that we get dm_keys and other participant IDs
      dm_keys = Enum.map(threads, & &1.dm_key)
      participant_ids = Enum.map(threads, & &1.other_participant_id)

      assert user_b in participant_ids
      assert user_c in participant_ids
      assert Chat.generate_dm_key(user_a, user_b) in dm_keys
      assert Chat.generate_dm_key(user_a, user_c) in dm_keys
    end
  end

  describe "broadcast messaging" do
    test "send_broadcast_message/3 creates a broadcast message" do
      sender_id = "admin:system"

      assert {:ok, message} = Chat.send_broadcast_message(sender_id, "Broadcast!")

      assert message.sender_id == sender_id
      assert message.text == "Broadcast!"
    end

    test "list_broadcast_messages/1 returns broadcast messages" do
      sender_id = "admin:system"

      {:ok, _msg1} = Chat.send_broadcast_message(sender_id, "First")
      {:ok, _msg2} = Chat.send_broadcast_message(sender_id, "Second")

      messages = Chat.list_broadcast_messages()

      assert length(messages) == 2
      message_texts = Enum.map(messages, & &1.text)
      assert "First" in message_texts
      assert "Second" in message_texts

      # Verify ordering by created_at DESC (most recent first)
      [first, second] = messages
      assert first.created_at >= second.created_at
    end
  end

  describe "message dispatching" do
    test "dispatch_message/2 routes DM messages correctly" do
      sender_id = "user:alice"
      recipient_id = "user:bob"

      attrs = %{
        sender_id: sender_id,
        recipient_id: recipient_id,
        text: "Dispatched DM"
      }

      assert {:ok, message} = Chat.dispatch_message(attrs)
      assert message.sender_id == sender_id
      assert message.recipient_id == recipient_id
    end

    test "dispatch_message/2 routes broadcast messages correctly" do
      sender_id = "admin:system"

      attrs = %{
        sender_id: sender_id,
        text: "Dispatched broadcast"
      }

      assert {:ok, message} = Chat.dispatch_message(attrs)
      assert message.sender_id == sender_id
      assert message.text == "Dispatched broadcast"
    end

    test "dispatch_message/2 fails with invalid attributes" do
      attrs = %{text: "No sender"}

      assert {:error, "missing sender_id or invalid message type"} = Chat.dispatch_message(attrs)
    end
  end
end