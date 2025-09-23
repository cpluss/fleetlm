defmodule FleetlmWeb.InboxChannelTest do
  use FleetlmWeb.ChannelCase

  alias Fleetlm.Chat
  alias FleetlmWeb.InboxChannel

  describe "InboxChannel" do
    setup do
      user_a = "user:alice"
      user_b = "user:bob"

      {:ok, _} = Chat.send_message(user_a, user_b, "Hello Bob")
      :timer.sleep(10)
      {:ok, _} = Chat.send_message(user_b, user_a, "Hi Alice")

      {:ok, user_a: user_a, user_b: user_b}
    end

    test "joining inbox channel returns empty snapshot", %{user_a: user_a} do
      {:ok, socket} = connect(FleetlmWeb.UserSocket, %{"participant_id" => user_a})
      {:ok, reply, _socket} = subscribe_and_join(socket, InboxChannel, "inbox:#{user_a}")

      assert %{"conversations" => conversations} = reply
      assert conversations == []
    end

    test "dm metadata updates flow through inbox channel", %{user_a: user_a, user_b: user_b} do
      {:ok, socket_a} = connect(FleetlmWeb.UserSocket, %{"participant_id" => user_a})
      {:ok, _reply, inbox_socket} = subscribe_and_join(socket_a, InboxChannel, "inbox:#{user_a}")

      dm_key = Chat.generate_dm_key(user_a, user_b)
      {:ok, _} = Chat.send_message(user_b, user_a, "New ping")

      update = wait_for_update(inbox_socket, dm_key)
      assert update["participant_id"] == user_a
      assert update["other_participant_id"] == user_b
      assert update["last_sender_id"] == user_b
      assert update["last_message_text"] in [nil, ""]
    end

    test "unauthorized participant cannot join inbox channel" do
      {:ok, socket} = connect(FleetlmWeb.UserSocket, %{"participant_id" => "user:charlie"})

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(socket, InboxChannel, "inbox:user:alice")
    end
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
