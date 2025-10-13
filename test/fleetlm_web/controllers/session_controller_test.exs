defmodule FleetlmWeb.SessionControllerTest do
  use Fleetlm.TestCase, mode: :conn

  describe "POST /api/sessions" do
    test "creates a session with user_id and agent_id", %{conn: conn} do
      conn =
        post(conn, ~p"/api/sessions", %{
          "user_id" => "alice",
          "agent_id" => "agent:echo"
        })

      assert %{"session" => session} = json_response(conn, 201)
      assert session["user_id"] == "alice"
      assert session["agent_id"] == "agent:echo"
      assert Map.has_key?(session, "status")
      assert Map.has_key?(session, "metadata")
    end

    test "rejects legacy sender_id payloads", %{conn: conn} do
      conn =
        post(conn, ~p"/api/sessions", %{
          "sender_id" => "alice",
          "recipient_id" => "agent:echo"
        })

      assert %{"error" => "user_id and agent_id are required"} = json_response(conn, 422)
    end
  end

  describe "GET /api/sessions/:id/messages" do
    test "hydrates without relying on sender_id", %{conn: conn} do
      session = create_test_session("alice", "agent:echo")

      conn = get(conn, ~p"/api/sessions/#{session.id}/messages")

      assert %{"messages" => messages} = json_response(conn, 200)
      assert messages == []
    end
  end

  describe "POST /api/sessions/:id/messages" do
    test "accepts user_id as the author", %{conn: conn} do
      session = create_test_session("alice", "agent:echo")

      conn =
        post(conn, ~p"/api/sessions/#{session.id}/messages", %{
          "session_id" => session.id,
          "user_id" => session.user_id,
          "kind" => "text",
          "content" => %{"text" => "hi"}
        })

      assert %{"message" => message} = json_response(conn, 200)
      assert message["seq"] == 1
      assert message["session_id"] == session.id
    end

    test "rejects deprecated sender_id field", %{conn: conn} do
      session = create_test_session("alice", "agent:echo")

      conn =
        post(conn, ~p"/api/sessions/#{session.id}/messages", %{
          "session_id" => session.id,
          "sender_id" => session.user_id,
          "kind" => "text",
          "content" => %{"text" => "hi"}
        })

      assert %{"error" => message} = json_response(conn, 422)
      assert message =~ "sender_id is deprecated"
    end

    test "rejects payloads specifying both user and agent", %{conn: conn} do
      session = create_test_session("alice", "agent:echo")

      conn =
        post(conn, ~p"/api/sessions/#{session.id}/messages", %{
          "session_id" => session.id,
          "user_id" => session.user_id,
          "agent_id" => session.agent_id,
          "content" => %{"text" => "dual"}
        })

      assert %{"error" => message} = json_response(conn, 422)
      assert message =~ "either user_id or agent_id"
    end
  end
end
