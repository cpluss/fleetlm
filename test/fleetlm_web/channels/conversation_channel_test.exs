defmodule FleetlmWeb.ConversationChannelTest do
  use FleetlmWeb.ChannelCase

  @moduletag skip: "Legacy chat runtime pending replacement"

  alias Fleetlm.Chat
  alias FleetlmWeb.ConversationChannel

  describe "ConversationChannel" do
    setup do
      user_a = "user:alice"
      user_b = "user:bob"
      dm_key = Chat.generate_dm_key(user_a, user_b)

      {:ok, _} = Chat.send_message(user_a, user_b, "Message 1")
      :timer.sleep(10)
      {:ok, _} = Chat.send_message(user_b, user_a, "Message 2")

      {:ok, user_a: user_a, user_b: user_b, dm_key: dm_key}
    end

    test "joining returns conversation history", %{user_a: user_a, dm_key: dm_key} do
      {:ok, socket} = connect(FleetlmWeb.UserSocket, %{"participant_id" => user_a})

      {:ok, reply, _socket} =
        subscribe_and_join(socket, ConversationChannel, "conversation:" <> dm_key)

      assert %{"dm_key" => ^dm_key, "messages" => messages} = reply
      assert Enum.map(messages, & &1["text"]) == ["Message 1", "Message 2"]
    end

    test "sending a message broadcasts to subscribers", %{
      user_a: user_a,
      user_b: user_b,
      dm_key: dm_key
    } do
      {:ok, socket_a} = connect(FleetlmWeb.UserSocket, %{"participant_id" => user_a})

      {:ok, _reply, _socket_a} =
        subscribe_and_join(socket_a, ConversationChannel, "conversation:" <> dm_key)

      {:ok, socket_b} = connect(FleetlmWeb.UserSocket, %{"participant_id" => user_b})

      {:ok, _reply, _socket_b} =
        subscribe_and_join(socket_b, ConversationChannel, "conversation:" <> dm_key)

      {:ok, _} = Chat.send_message(user_a, user_b, "Hello from A")

      assert_receive %Phoenix.Socket.Message{
        event: "message",
        payload: %{"sender_id" => ^user_a, "text" => "Hello from A"}
      }

      assert_receive %Phoenix.Socket.Message{
        event: "message",
        payload: %{"sender_id" => ^user_a, "text" => "Hello from A"}
      }
    end

    test "broadcast conversation can be joined" do
      {:ok, socket} = connect(FleetlmWeb.UserSocket, %{"participant_id" => "user:alice"})

      {:ok, reply, _socket} =
        subscribe_and_join(socket, ConversationChannel, "conversation:broadcast")

      assert %{"dm_key" => "broadcast", "messages" => []} = reply

      {:ok, _} = Chat.send_broadcast_message("user:alice", "Hi all")

      assert_receive %Phoenix.Socket.Message{event: "message", payload: %{"text" => "Hi all"}}
    end
  end
end
