defmodule FleetlmWeb.SessionChannelTest do
  use Fleetlm.TestCase, mode: :channel

  alias Fleetlm.Runtime
  alias Fleetlm.Storage, as: StorageAPI
  alias FleetlmWeb.SessionChannel

  setup do
    # Create session using storage API
    {:ok, session} = StorageAPI.create_session("user:alice", "agent:bot", %{})

    {:ok, session: session}
  end

  test "join returns message history", %{session: session} do
    {:ok, _} =
      Runtime.append_message(
        session.id,
        "user:alice",
        "agent:bot",
        "text",
        %{"text" => "hello"},
        %{}
      )

    {:ok, socket} = connect(FleetlmWeb.UserSocket, %{"user_id" => "user:alice"})

    session_id = session.id

    {:ok, reply, _socket} =
      subscribe_and_join(socket, SessionChannel, "session:" <> session_id)

    assert %{
             session_id: ^session_id,
             messages: [%{"content" => %{"text" => "hello"}}]
           } = reply
  end

  test "only participants may join", %{session: session} do
    {:ok, socket} = connect(FleetlmWeb.UserSocket, %{"user_id" => "user:mallory"})

    assert {:error, %{reason: "unauthorized"}} =
             subscribe_and_join(socket, SessionChannel, "session:" <> session.id)
  end

  test "pushes stream chunks to clients", %{session: session} do
    {:ok, socket} = connect(FleetlmWeb.UserSocket, %{"user_id" => session.user_id})
    {:ok, _reply, socket} = subscribe_and_join(socket, SessionChannel, "session:" <> session.id)

    payload = %{
      "agent_id" => session.agent_id,
      "chunk" => %{"type" => "text-delta", "delta" => "Hi"}
    }

    send(socket.channel_pid, {:session_stream_chunk, payload})
    assert_push("stream_chunk", ^payload)
  end
end
