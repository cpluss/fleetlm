defmodule FleetlmWeb.SessionChannelTest do
  use Fleetlm.TestCase, mode: :channel

  alias Fleetlm.Runtime.{Router, SessionSupervisor}
  alias FleetLM.Storage.API
  alias FleetlmWeb.SessionChannel

  setup do
    # Create session using new storage model
    {:ok, session} = API.create_session("user:alice", "agent:bot", %{})

    # Ensure SessionServer is started and has DB access
    {:ok, pid} = SessionSupervisor.ensure_started(session.id)
    Fleetlm.DataCase.allow_sandbox_access(pid)

    {:ok, session: session}
  end

  test "join returns message history", %{session: session} do
    {:ok, _} =
      Router.append_message(
        session.id,
        "user:alice",
        "text",
        %{"text" => "hello"},
        %{}
      )

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
