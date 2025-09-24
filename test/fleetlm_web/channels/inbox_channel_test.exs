defmodule FleetlmWeb.InboxChannelTest do
  use FleetlmWeb.ChannelCase

  alias Fleetlm.Chat
  alias Fleetlm.Chat.{Cache, InboxServer, InboxSupervisor, DmKey}
  alias FleetlmWeb.InboxChannel

  describe "InboxChannel" do
    setup do
      user_a = "user:alice"
      user_b = "user:bob"

      Cache.reset()
      {:ok, _} = InboxSupervisor.ensure_started(user_a)
      {:ok, _} = InboxSupervisor.ensure_started(user_b)

      {:ok, _} = Chat.send_message(user_a, user_b, "Hello Bob")
      :timer.sleep(10)
      {:ok, _} = Chat.send_message(user_b, user_a, "Hi Alice")

      {:ok, user_a: user_a, user_b: user_b}
    end

    test "joining inbox channel returns snapshot", %{user_a: user_a, user_b: user_b} do
      {:ok, socket} = connect(FleetlmWeb.UserSocket, %{"participant_id" => user_a})
      {:ok, reply, _socket} = subscribe_and_join(socket, InboxChannel, "inbox:#{user_a}")

      assert %{"conversations" => conversations} = reply
      assert length(conversations) == 1
      conversation = hd(conversations)

      parsed = DmKey.parse!(conversation["dm_key"])
      participants = [parsed.first, parsed.second]
      assert Enum.sort(participants) == Enum.sort([user_a, user_b])
    end

    test "dm metadata updates flow through inbox channel", %{user_a: user_a, user_b: user_b} do
      {:ok, socket_a} = connect(FleetlmWeb.UserSocket, %{"participant_id" => user_a})
      {:ok, _reply, inbox_socket} = subscribe_and_join(socket_a, InboxChannel, "inbox:#{user_a}")

      dm_key = Chat.generate_dm_key(user_a, user_b)
      {:ok, _} = Chat.send_message(user_b, user_a, "New ping")
      :ok = InboxServer.flush(user_a)

      update = wait_for_update(inbox_socket, dm_key)
      assert update["last_sender_id"] == user_b
      assert update["last_message_text"] == "New ping"
    end

    test "aggregated deltas include multiple conversations", %{user_a: user_a, user_b: user_b} do
      user_c = "user:carol"

      {:ok, socket_a} = connect(FleetlmWeb.UserSocket, %{"participant_id" => user_a})
      {:ok, _reply, _inbox_socket} = subscribe_and_join(socket_a, InboxChannel, "inbox:#{user_a}")

      {:ok, _} = Chat.send_message(user_b, user_a, "Ping B")
      {:ok, _} = Chat.send_message(user_c, user_a, "Ping C")

      :ok = InboxServer.flush(user_a)

      assert_receive %Phoenix.Socket.Message{event: "tick", payload: %{"updates" => updates}}
      assert length(updates) == 2

      parsed_participants =
        updates
        |> Enum.map(&DmKey.parse!(&1["dm_key"]))
        |> Enum.map(fn dm ->
          if dm.first == user_a, do: dm.second, else: dm.first
        end)

      assert Enum.sort(parsed_participants) == Enum.sort([user_b, user_c])

      Enum.each(updates, fn update ->
        refute Map.has_key?(update, "text")
        refute Map.has_key?(update, "metadata")
      end)

      :ok
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
