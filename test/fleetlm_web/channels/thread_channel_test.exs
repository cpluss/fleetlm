defmodule FleetlmWeb.ThreadChannelTest do
  use FleetlmWeb.ChannelCase

  alias Fleetlm.Chat

  setup do
    participant_id = Ecto.UUID.generate()
    other_id = Ecto.UUID.generate()
    thread = Chat.ensure_dm!(participant_id, other_id)

    {:ok, %{participant_id: participant_id, other_id: other_id, thread: thread}}
  end

  test "join returns latest history", %{participant_id: participant_id, thread: thread} do
    {:ok, socket} = connect(UserSocket, %{"participant_id" => participant_id})
    {:ok, reply, _socket} = subscribe_and_join(socket, "thread:#{thread.id}", %{})
    assert %{"messages" => []} = reply
  end

  test "join preloads existing messages", %{participant_id: participant_id, thread: thread} do
    {:ok, _message} =
      Chat.send_message(%{thread_id: thread.id, sender_id: participant_id, text: "backlog"})

    {:ok, socket} = connect(UserSocket, %{"participant_id" => participant_id})
    {:ok, reply, _socket} = subscribe_and_join(socket, "thread:#{thread.id}", %{})

    assert %{"messages" => [%{"text" => "backlog"}]} = reply
  end

  test "message send replies and pushes", %{participant_id: participant_id, thread: thread} do
    {:ok, socket} = connect(UserSocket, %{"participant_id" => participant_id})
    {:ok, _reply, socket} = subscribe_and_join(socket, "thread:#{thread.id}", %{})

    ref = push(socket, "message:new", %{"text" => "hello"})

    assert_reply ref, :ok, %{"text" => "hello", "sender_id" => ^participant_id}
    assert_push "message", %{"text" => "hello", "sender_id" => ^participant_id}
  end

  test "receives broadcast when other participant sends", %{
    participant_id: participant_id,
    other_id: other_id,
    thread: thread
  } do
    {:ok, socket} = connect(UserSocket, %{"participant_id" => participant_id})
    {:ok, _reply, socket2} = subscribe_and_join(socket, "thread:#{thread.id}", %{})

    {:ok, pid} = Chat.ensure_thread_runtime(thread.id)
    Ecto.Adapters.SQL.Sandbox.allow(Fleetlm.Repo, self(), pid)

    {:ok, _message} =
      Chat.dispatch_message(%{
        "thread_id" => thread.id,
        "sender_id" => other_id,
        "text" => "broadcast"
      })

    assert_push "message", %{"text" => "broadcast", "sender_id" => ^other_id}
    leave(socket2)
  end

  test "refuses join for non participant", %{thread: thread} do
    {:ok, socket} = connect(UserSocket, %{"participant_id" => Ecto.UUID.generate()})

    assert {:error, %{reason: "unauthorized"}} =
             subscribe_and_join(socket, "thread:#{thread.id}", %{})
  end

  test "rejects join for missing thread" do
    {:ok, socket} = connect(UserSocket, %{"participant_id" => Ecto.UUID.generate()})

    assert {:error, %{reason: "unauthorized"}} =
             subscribe_and_join(socket, "thread:#{Ecto.UUID.generate()}", %{})
  end
end
