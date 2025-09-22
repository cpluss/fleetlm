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

    test "joining participant channel returns dm_threads with dm_keys", %{
      user_a: user_a,
      user_b: user_b
    } do
      {:ok, socket} = connect(FleetlmWeb.UserSocket, %{"participant_id" => user_a})

      {:ok, reply, _socket} =
        subscribe_and_join(socket, ParticipantChannel, "participant:#{user_a}")

      assert %{"dm_threads" => dm_threads} = reply
      assert Enum.any?(dm_threads, &(&1["dm_key"] == Chat.generate_dm_key(user_a, user_b)))
    end

    test "receives dm_activity metadata when not subscribed to dm channel", %{
      user_a: user_a,
      user_b: user_b
    } do
      # Subscribe to participant channels only (not dm channel)
      {:ok, socket_a} = connect(FleetlmWeb.UserSocket, %{"participant_id" => user_a})

      {:ok, _reply, _socket_a} =
        subscribe_and_join(socket_a, ParticipantChannel, "participant:#{user_a}")

      # Send a message from B to A via ThreadChannel
      dm_key = Chat.generate_dm_key(user_a, user_b)
      {:ok, dm_socket} = connect(FleetlmWeb.UserSocket, %{"participant_id" => user_b})

      {:ok, _reply, dm_socket} =
        subscribe_and_join(dm_socket, FleetlmWeb.ThreadChannel, "dm:#{dm_key}")

      ref = push(dm_socket, "message:new", %{"text" => "New message from B"})
      assert_reply ref, :ok

      # Check that user_a gets the metadata update via ParticipantChannel
      assert_push "tick", %{"updates" => updates}, 2000

      # Verify the metadata structure
      update = Enum.find(updates, fn update -> update["dm_key"] == dm_key end)
      refute is_nil(update)
      assert update["last_sender_id"] == user_b
      assert update["last_message_text"] == "New message from B"
    end

    test "dm:create notifies both participants about new DM thread", %{user_b: user_b} do
      # New user for this test
      user_c = "user:charlie"

      # Connect both participants to their channels
      {:ok, socket_b} = connect(FleetlmWeb.UserSocket, %{"participant_id" => user_b})

      {:ok, _reply_b, socket_b} =
        subscribe_and_join(socket_b, ParticipantChannel, "participant:#{user_b}")

      {:ok, socket_c} = connect(FleetlmWeb.UserSocket, %{"participant_id" => user_c})

      {:ok, _reply_c, socket_c} =
        subscribe_and_join(socket_c, ParticipantChannel, "participant:#{user_c}")

      # User B creates a new DM with user C
      ref =
        push(socket_b, "dm:create", %{"participant_id" => user_c, "message" => "Hello Charlie!"})

      assert_reply ref, :ok, reply

      expected_dm_key = Chat.generate_dm_key(user_b, user_c)
      assert %{"dm_key" => ^expected_dm_key} = reply

      # Both participants should receive dm_activity notifications
      # User B should get notification about the DM they created
      update_b = wait_for_update(socket_b, expected_dm_key)
      assert update_b["last_sender_id"] == user_b
      assert update_b["last_message_text"] == "Hello Charlie!"
      assert update_b["other_participant_id"] == user_c

      # User C should get notification about the new DM (need to use socket_c here)
      update_c = wait_for_update(socket_c, expected_dm_key)
      assert update_c["last_sender_id"] == user_b
      assert update_c["last_message_text"] == "Hello Charlie!"
      # Swapped for recipient
      assert update_c["other_participant_id"] == user_b
    end

    test "dm:create without message still notifies both participants", %{user_a: user_a} do
      user_d = "user:david"

      # Connect both participants
      {:ok, socket_a} = connect(FleetlmWeb.UserSocket, %{"participant_id" => user_a})

      {:ok, _reply_a, socket_a} =
        subscribe_and_join(socket_a, ParticipantChannel, "participant:#{user_a}")

      {:ok, socket_d} = connect(FleetlmWeb.UserSocket, %{"participant_id" => user_d})

      {:ok, _reply_d, socket_d} =
        subscribe_and_join(socket_d, ParticipantChannel, "participant:#{user_d}")

      # User A creates DM without initial message
      ref = push(socket_a, "dm:create", %{"participant_id" => user_d, "message" => ""})
      assert_reply ref, :ok, reply

      expected_dm_key = Chat.generate_dm_key(user_a, user_d)
      assert %{"dm_key" => ^expected_dm_key} = reply

      # Both should get notifications even without a message
      update_a = wait_for_update(socket_a, expected_dm_key)
      assert update_a["last_sender_id"] in [user_a, nil]
      assert update_a["last_message_text"] == nil
      assert update_a["other_participant_id"] == user_d

      update_d = wait_for_update(socket_d, expected_dm_key)
      assert update_d["last_sender_id"] in [user_a, nil]
      assert update_d["last_message_text"] == nil
      assert update_d["other_participant_id"] == user_a
    end

    test "unauthorized participant cannot join others' channels" do
      user_c = "user:charlie"

      {:ok, socket} = connect(FleetlmWeb.UserSocket, %{"participant_id" => user_c})

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(socket, ParticipantChannel, "participant:user:alice")
    end

    defp wait_for_update(socket, dm_key, attempts \\ 5)

    defp wait_for_update(_socket, _dm_key, 0), do: flunk("did not receive expected dm activity")

    defp wait_for_update(socket, dm_key, attempts) do
      receive do
        %Phoenix.Socket.Message{topic: topic, event: "tick", payload: %{"updates" => updates}}
        when topic == socket.topic ->
          case Enum.find(updates, fn update -> update["dm_key"] == dm_key end) do
            nil -> wait_for_update(socket, dm_key, attempts - 1)
            update -> update
          end
      after
        500 -> wait_for_update(socket, dm_key, attempts - 1)
      end
    end
  end
end
