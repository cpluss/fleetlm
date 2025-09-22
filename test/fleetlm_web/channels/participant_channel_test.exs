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

    test "unauthorized participant cannot join others' channels" do
      user_c = "user:charlie"

      {:ok, socket} = connect(FleetlmWeb.UserSocket, %{"participant_id" => user_c})

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(socket, ParticipantChannel, "participant:user:alice")
    end
  end
end