defmodule FleetlmWeb.ParticipantChannelTest do
  use FleetlmWeb.ChannelCase

  alias Fleetlm.Chat
  alias Fleetlm.Chat.ThreadServer

  setup do
    participant_id = Ecto.UUID.generate()
    other_id = Ecto.UUID.generate()
    thread = Chat.ensure_dm!(participant_id, other_id)

    {:ok, socket} = connect(UserSocket, %{"participant_id" => participant_id})
    {:ok, reply, socket} = subscribe_and_join(socket, "participant:#{participant_id}", %{})

    {:ok,
     %{
       socket: socket,
       participant_id: participant_id,
       other_id: other_id,
       thread: thread,
       reply: reply
     }}
  end

  test "join returns thread metadata", %{reply: reply, thread: thread} do
    assert %{"threads" => [thread_info]} = reply
    assert thread_info["thread"]["id"] == thread.id
  end

  test "tick returns updates when new messages arrive", %{
    socket: _socket,
    thread: thread,
    other_id: other_id
  } do
    thread_id = thread.id

    {:ok, pid} = Chat.ensure_thread_runtime(thread_id)
    Ecto.Adapters.SQL.Sandbox.allow(Fleetlm.Repo, self(), pid)

    {:ok, _message} =
      ThreadServer.send_message(thread_id, %{
        thread_id: thread_id,
        sender_id: other_id,
        text: "hello"
      })

    assert_push "tick", %{"updates" => [update]}

    assert update["thread_id"] == thread_id
    assert update["last_message_preview"] == "hello"
    assert update["sender_id"] == other_id

    refute_receive(%Phoenix.Socket.Message{event: "tick"}, 150)
  end

  test "does not emit tick without updates" do
    refute_receive(%Phoenix.Socket.Message{event: "tick"}, 150)
    refute_receive(%Phoenix.Socket.Message{event: "tick"}, 150)
  end

  test "push delivers thread summary events", %{
    participant_id: participant_id,
    thread: thread,
    socket: socket
  } do
    thread_id = thread.id
    now = DateTime.utc_now()
    encoded_now = DateTime.to_iso8601(now)

    send(
      socket.channel_pid,
      {:thread_updated,
       %{
         thread_id: thread_id,
         participant_id: participant_id,
         last_message_at: now,
         last_message_preview: "ping",
         sender_id: participant_id
       }}
    )

    assert_push "tick",
                %{
                  "updates" => [
                    %{
                      "thread_id" => ^thread_id,
                      "last_message_preview" => "ping",
                      "participant_id" => ^participant_id,
                      "last_message_at" => ^encoded_now
                    }
                  ]
                },
                300
  end

  test "refuses join for mismatched participant" do
    {:ok, socket} = connect(UserSocket, %{"participant_id" => Ecto.UUID.generate()})

    assert {:error, %{reason: "unauthorized"}} =
             subscribe_and_join(socket, "participant:#{Ecto.UUID.generate()}", %{})
  end
end
