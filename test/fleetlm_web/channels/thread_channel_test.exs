defmodule FleetlmWeb.ThreadChannelTest do
  use FleetlmWeb.ChannelCase

  alias Fleetlm.Chat

  describe "DM channels" do
    setup do
      user_a = "user:alice"
      user_b = "user:bob"
      dm_key = Chat.generate_dm_key(user_a, user_b)

      {:ok, user_a: user_a, user_b: user_b, dm_key: dm_key}
    end

    test "joining a DM channel returns message history", %{
      user_a: user_a,
      user_b: user_b,
      dm_key: dm_key
    } do
      # Pre-populate some messages
      {:ok, _} = Chat.send_dm_message(user_a, user_b, "Message 1")
      {:ok, _} = Chat.send_dm_message(user_b, user_a, "Message 2")

      {:ok, socket} = connect(FleetlmWeb.UserSocket, %{"participant_id" => user_a})
      {:ok, reply, _socket} = subscribe_and_join(socket, FleetlmWeb.ThreadChannel, "dm:#{dm_key}")

      assert %{"messages" => messages, "dm_key" => ^dm_key} = reply
      assert length(messages) == 2
      assert Enum.any?(messages, &(&1["text"] == "Message 1"))
      assert Enum.any?(messages, &(&1["text"] == "Message 2"))
    end

    test "sending a DM message broadcasts to channel", %{user_a: user_a, dm_key: dm_key} do
      {:ok, socket} = connect(FleetlmWeb.UserSocket, %{"participant_id" => user_a})
      {:ok, _reply, socket} = subscribe_and_join(socket, FleetlmWeb.ThreadChannel, "dm:#{dm_key}")

      ref = push(socket, "message:new", %{"text" => "Hello from A"})
      assert_reply ref, :ok, %{"sender_id" => ^user_a, "text" => "Hello from A"}

      assert_push "message", %{"sender_id" => ^user_a, "text" => "Hello from A"}
    end

    test "unauthorized users cannot join DM channels", %{dm_key: dm_key} do
      user_c = "user:charlie"

      {:ok, socket} = connect(FleetlmWeb.UserSocket, %{"participant_id" => user_c})

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(socket, FleetlmWeb.ThreadChannel, "dm:#{dm_key}")
    end
  end

  describe "broadcast channels" do
    test "joining broadcast channel returns recent messages" do
      sender_id = "admin:system"
      {:ok, _} = Chat.send_broadcast_message(sender_id, "Broadcast message")

      {:ok, socket} = connect(FleetlmWeb.UserSocket, %{"participant_id" => "user:alice"})
      {:ok, reply, _socket} = subscribe_and_join(socket, FleetlmWeb.ThreadChannel, "broadcast")

      assert %{"messages" => messages} = reply
      assert length(messages) == 1
      assert List.first(messages)["text"] == "Broadcast message"
    end

    test "sending broadcast message broadcasts to all listeners" do
      user_id = "admin:system"

      {:ok, socket} = connect(FleetlmWeb.UserSocket, %{"participant_id" => user_id})
      {:ok, _reply, socket} = subscribe_and_join(socket, FleetlmWeb.ThreadChannel, "broadcast")

      ref = push(socket, "message:new", %{"text" => "Hello everyone"})
      assert_reply ref, :ok, %{"sender_id" => ^user_id, "text" => "Hello everyone"}

      assert_push "message", %{"sender_id" => ^user_id, "text" => "Hello everyone"}
    end
  end
end
