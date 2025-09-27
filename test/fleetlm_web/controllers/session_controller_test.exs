defmodule FleetlmWeb.SessionControllerTest do
  use FleetlmWeb.ConnCase

  alias Fleetlm.Runtime.Gateway
  alias Fleetlm.Participants
  alias Fleetlm.Sessions

  setup %{conn: conn} do
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

    %{conn: conn}
  end

  test "POST /api/sessions creates a session", %{conn: conn} do
    conn =
      post(conn, ~p"/api/sessions", %{
        "initiator_id" => "user:alice",
        "peer_id" => "agent:bot"
      })

    assert %{
             "session" => %{"id" => id, "initiator_id" => "user:alice", "agent_id" => "agent:bot"}
           } =
             json_response(conn, 201)

    assert Sessions.get_session!(id)
  end

  test "GET /api/sessions/:id/messages returns messages", %{conn: conn} do
    {:ok, session} =
      Sessions.start_session(%{
        initiator_id: "user:alice",
        peer_id: "agent:bot"
      })

    {:ok, _} =
      Gateway.append_message(session.id, %{
        sender_id: "user:alice",
        kind: "text",
        content: %{text: "hi"}
      })

    conn = get(conn, ~p"/api/sessions/#{session.id}/messages")
    assert %{"messages" => [message]} = json_response(conn, 200)
    assert message["session_id"] == session.id
  end

  test "POST /api/sessions/:id/messages appends message", %{conn: conn} do
    {:ok, session} =
      Sessions.start_session(%{
        initiator_id: "user:alice",
        peer_id: "agent:bot"
      })

    session_id = session.id

    conn =
      post(conn, ~p"/api/sessions/#{session_id}/messages", %{
        "sender_id" => "user:alice",
        "content" => %{text: "hello"}
      })

    assert %{"message" => %{"session_id" => ^session_id, "content" => %{"text" => "hello"}}} =
             json_response(conn, 200)
  end

  test "POST /api/sessions/:id/read marks session as read", %{conn: conn} do
    {:ok, session} =
      Sessions.start_session(%{
        initiator_id: "user:alice",
        peer_id: "agent:bot"
      })

    {:ok, message} =
      Gateway.append_message(session.id, %{
        sender_id: "user:alice",
        kind: "text",
        content: %{text: "ping"}
      })

    conn =
      post(conn, ~p"/api/sessions/#{session.id}/read", %{
        "participant_id" => "agent:bot",
        "message_id" => message.id
      })

    assert %{
             "session" => %{
               "peer_last_read_id" => peer_last_read_id,
               "peer_last_read_at" => peer_last_read_at
             }
           } =
             json_response(conn, 200)

    assert peer_last_read_id == message.id
    assert is_binary(peer_last_read_at)
  end
end
