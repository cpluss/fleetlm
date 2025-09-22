defmodule FleetlmWeb.ParticipantChannelTest do
  use FleetlmWeb.ChannelCase

  alias Fleetlm.Chat
  alias FleetlmWeb.ParticipantChannel

  describe "ParticipantChannel" do
    setup do
      user_a = "user:alice"
      user_b = "user:bob"

      # Create some DM history
      {:ok, _} = Chat.send_dm_message(user_a, user_b, "Hello Bob")
      # Small delay to ensure ordering
      :timer.sleep(10)
      {:ok, _} = Chat.send_dm_message(user_b, user_a, "Hi Alice")

      {:ok, user_a: user_a, user_b: user_b}
    end

    test "joining participant channel returns dm_threads with dm_keys", %{user_a: user_a, user_b: user_b} do
      {:ok, socket} = connect(FleetlmWeb.UserSocket, %{"participant_id" => user_a})
      {:ok, reply, _socket} = subscribe_and_join(socket, ParticipantChannel, "participant:#{user_a}")

      assert %{"dm_threads" => dm_threads} = reply
      assert length(dm_threads) == 1

      thread = List.first(dm_threads)
      assert thread["dm_key"] == Chat.generate_dm_key(user_a, user_b)
      assert thread["other_participant_id"] == user_b
      assert thread["last_message_text"] in ["Hello Bob", "Hi Alice"]
      assert thread["last_message_at"]
    end

    test "receives dm_activity metadata when not subscribed to dm channel", %{user_a: user_a, user_b: user_b} do
      # Subscribe to participant channels only (not dm channel)
      {:ok, socket_a} = connect(FleetlmWeb.UserSocket, %{"participant_id" => user_a})
      {:ok, _reply, _socket_a} = subscribe_and_join(socket_a, ParticipantChannel, "participant:#{user_a}")

      # Send a message from B to A via ThreadChannel
      dm_key = Chat.generate_dm_key(user_a, user_b)
      {:ok, dm_socket} = connect(FleetlmWeb.UserSocket, %{"participant_id" => user_b})
      {:ok, _reply, dm_socket} = subscribe_and_join(dm_socket, FleetlmWeb.ThreadChannel, "dm:#{dm_key}")

      ref = push(dm_socket, "message:new", %{"text" => "New message from B"})
      assert_reply ref, :ok

      # Wait for the tick to deliver the metadata update
      :timer.sleep(1100)  # Slightly longer than tick interval

      # Check that user_a gets the metadata update via ParticipantChannel
      assert_push "tick", %{"updates" => updates}, 2000

      # Verify the metadata structure
      assert length(updates) == 1
      update = List.first(updates)

      assert update[:dm_key] == dm_key
      assert update[:sender_id] == user_b
      assert update[:last_message_text] == "New message from B"
      assert update[:event] == "dm_activity"
    end

    test "dm:create notifies both participants about new DM thread", %{user_b: user_b} do
      user_c = "user:charlie"  # New user for this test

      # Connect both participants to their channels
      {:ok, socket_b} = connect(FleetlmWeb.UserSocket, %{"participant_id" => user_b})
      {:ok, _reply_b, socket_b} = subscribe_and_join(socket_b, ParticipantChannel, "participant:#{user_b}")

      {:ok, socket_c} = connect(FleetlmWeb.UserSocket, %{"participant_id" => user_c})
      {:ok, _reply_c, socket_c} = subscribe_and_join(socket_c, ParticipantChannel, "participant:#{user_c}")

      # User B creates a new DM with user C
      ref = push(socket_b, "dm:create", %{"participant_id" => user_c, "message" => "Hello Charlie!"})
      assert_reply ref, :ok, reply

      expected_dm_key = Chat.generate_dm_key(user_b, user_c)
      assert %{"dm_key" => ^expected_dm_key} = reply

      # Both participants should receive dm_activity notifications
      # Wait for tick interval to deliver notifications
      :timer.sleep(1100)

      # User B should get notification about the DM they created
      assert_push "tick", %{"updates" => updates_b}, 2000
      assert length(updates_b) == 1
      update_b = List.first(updates_b)
      assert update_b[:dm_key] == expected_dm_key
      assert update_b[:sender_id] == user_b
      assert update_b[:last_message_text] == "Hello Charlie!"
      assert update_b[:other_participant_id] == user_c

      # User C should get notification about the new DM (need to use socket_c here)
      assert_push "tick", %{"updates" => updates_c}, 2000
      assert length(updates_c) == 1
      update_c = List.first(updates_c)
      assert update_c[:dm_key] == expected_dm_key
      assert update_c[:sender_id] == user_b
      assert update_c[:last_message_text] == "Hello Charlie!"
      assert update_c[:other_participant_id] == user_b  # Swapped for recipient
    end

    test "dm:create without message still notifies both participants", %{user_a: user_a} do
      user_d = "user:david"

      # Connect both participants
      {:ok, socket_a} = connect(FleetlmWeb.UserSocket, %{"participant_id" => user_a})
      {:ok, _reply_a, socket_a} = subscribe_and_join(socket_a, ParticipantChannel, "participant:#{user_a}")

      {:ok, socket_d} = connect(FleetlmWeb.UserSocket, %{"participant_id" => user_d})
      {:ok, _reply_d, socket_d} = subscribe_and_join(socket_d, ParticipantChannel, "participant:#{user_d}")

      # User A creates DM without initial message
      ref = push(socket_a, "dm:create", %{"participant_id" => user_d, "message" => ""})
      assert_reply ref, :ok, reply

      expected_dm_key = Chat.generate_dm_key(user_a, user_d)
      assert %{"dm_key" => ^expected_dm_key} = reply

      # Wait for tick notifications
      :timer.sleep(1100)

      # Both should get notifications even without a message
      assert_push "tick", %{"updates" => updates_a}, 2000
      assert length(updates_a) == 1
      update_a = List.first(updates_a)
      assert update_a[:dm_key] == expected_dm_key
      assert update_a[:sender_id] == user_a
      assert update_a[:last_message_text] == nil
      assert update_a[:other_participant_id] == user_d

      assert_push "tick", %{"updates" => updates_d}, 2000
      assert length(updates_d) == 1
      update_d = List.first(updates_d)
      assert update_d[:dm_key] == expected_dm_key
      assert update_d[:sender_id] == user_a
      assert update_d[:last_message_text] == nil
      assert update_d[:other_participant_id] == user_a
    end

    test "unauthorized participant cannot join others' channels" do
      user_c = "user:charlie"

      {:ok, socket} = connect(FleetlmWeb.UserSocket, %{"participant_id" => user_c})

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(socket, ParticipantChannel, "participant:user:alice")
    end
  end
end