defmodule FleetlmWeb.SessionChannelTest do
  use FleetlmWeb.ChannelCase

  alias Fleetlm.Participants
  alias Fleetlm.Runtime.{Gateway, SessionSupervisor}
  alias Fleetlm.Sessions
  alias FleetlmWeb.SessionChannel

  setup do
    {:ok, _} =
      Participants.upsert_participant(%{
        id: "user:alice",
        kind: "user",
        display_name: "Alice"
      })

    {:ok, _} =
      Participants.upsert_participant(%{
        id: "agent:bot",
        kind: "agent",
        display_name: "Bot"
      })

    {:ok, session} =
      Sessions.start_session(%{
        initiator_id: "user:alice",
        peer_id: "agent:bot"
      })

    {:ok, pid} = SessionSupervisor.ensure_started(session.id)
    Fleetlm.DataCase.allow_sandbox_access(pid)

    {:ok, session: session}
  end

  test "join returns message history", %{session: session} do
    {:ok, _} =
      Gateway.append_message(session.id, %{
        sender_id: "user:alice",
        kind: "text",
        content: %{text: "hello"}
      })

    {:ok, socket} = connect(FleetlmWeb.UserSocket, %{"participant_id" => "user:alice"})

    session_id = session.id

    {:ok, reply, _socket} =
      subscribe_and_join(socket, SessionChannel, "session:" <> session_id)

    assert %{
             session_id: ^session_id,
             messages: [%{"content" => %{"text" => "hello"}}]
           } = reply
  end

  test "only participants may join", %{session: session} do
    {:ok, socket} = connect(FleetlmWeb.UserSocket, %{"participant_id" => "user:mallory"})

    assert {:error, %{reason: "unauthorized"}} =
             subscribe_and_join(socket, SessionChannel, "session:" <> session.id)
  end
end
