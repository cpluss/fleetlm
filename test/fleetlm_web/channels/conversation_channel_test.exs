defmodule FleetlmWeb.ConversationChannelTest do
  use FleetlmWeb.ChannelCase

  alias Fleetlm.Chat
  alias FleetlmWeb.ConversationChannel

  describe "ConversationChannel" do
    setup do
      user_a = "user:alice"
      user_b = "user:bob"
      dm_key = Chat.generate_dm_key(user_a, user_b)

      {:ok, _} = Chat.send_dm_message(user_a, user_b, "Message 1")
      :timer.sleep(10)
      {:ok, _} = Chat.send_dm_message(user_b, user_a, "Message 2")

      {:ok, user_a: user_a, user_b: user_b, dm_key: dm_key}
    end

    test "subscribing returns conversation history", %{user_a: user_a, dm_key: dm_key} do
      {:ok, socket} = connect(FleetlmWeb.UserSocket, %{"participant_id" => user_a})
      {:ok, _reply, socket} = subscribe_and_join(socket, ConversationChannel, "conversation")

      ref = push(socket, "conversation:subscribe", %{"dm_key" => dm_key})
      assert_reply ref, :ok, %{"dm_key" => ^dm_key, "messages" => messages}
      assert Enum.map(messages, & &1["text"]) == ["Message 1", "Message 2"]
    end

    test "sending a message broadcasts to subscribers", %{
      user_a: user_a,
      user_b: user_b,
      dm_key: dm_key
    } do
      {:ok, socket_a} = connect(FleetlmWeb.UserSocket, %{"participant_id" => user_a})
      {:ok, _reply, socket_a} = subscribe_and_join(socket_a, ConversationChannel, "conversation")
      {:ok, socket_b} = connect(FleetlmWeb.UserSocket, %{"participant_id" => user_b})
      {:ok, _reply, socket_b} = subscribe_and_join(socket_b, ConversationChannel, "conversation")

      push(socket_a, "conversation:subscribe", %{"dm_key" => dm_key})
      push(socket_b, "conversation:subscribe", %{"dm_key" => dm_key})

      {:ok, _} = Chat.send_dm_message(user_a, user_b, "Hello from A")

      assert_receive %Phoenix.Socket.Message{
               event: "message",
               payload: %{"sender_id" => ^user_a, "text" => "Hello from A"}
             }
    end

    test "broadcast conversations can be subscribed to" do
      {:ok, socket} = connect(FleetlmWeb.UserSocket, %{"participant_id" => "user:alice"})
      {:ok, _reply, socket} = subscribe_and_join(socket, ConversationChannel, "conversation")

      ref = push(socket, "conversation:subscribe", %{"dm_key" => "broadcast"})
      assert_reply ref, :ok, %{"dm_key" => "broadcast", "messages" => []}

      {:ok, _} = Chat.send_broadcast_message("user:alice", "Hi all")

      assert_receive %Phoenix.Socket.Message{event: "message", payload: %{"text" => "Hi all"}}
    end
  end
end
