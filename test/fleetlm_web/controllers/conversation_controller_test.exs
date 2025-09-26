defmodule FleetlmWeb.ConversationControllerTest do
  use FleetlmWeb.ConnCase

  @moduletag skip: "Legacy chat runtime pending replacement"

  alias Fleetlm.Chat

  @endpoint FleetlmWeb.Endpoint

  describe "GET /api/conversations/:dm_key/messages" do
    setup do
      user_a = "user:alice"
      user_b = "user:bob"
      dm_key = Chat.generate_dm_key(user_a, user_b)

      {:ok, _} = Chat.send_message(user_a, user_b, "hello")
      :timer.sleep(5)
      {:ok, _} = Chat.send_message(user_b, user_a, "hi")

      {:ok, user_a: user_a, user_b: user_b, dm_key: dm_key}
    end

    test "returns conversation history", %{conn: conn, user_a: user_a, dm_key: dm_key} do
      conn = get(conn, ~p"/api/conversations/#{dm_key}/messages", participant_id: user_a)
      assert %{"messages" => messages} = json_response(conn, 200)
      assert Enum.map(messages, & &1["text"]) == ["hello", "hi"]
    end

    test "rejects unauthorized access", %{conn: conn, dm_key: dm_key} do
      conn = get(conn, ~p"/api/conversations/#{dm_key}/messages", participant_id: "user:mallory")
      assert %{"error" => "unauthorized"} = json_response(conn, 403)
    end
  end

  describe "POST /api/conversations/:dm_key/messages" do
    setup do
      user_a = "user:alice"
      user_b = "user:bob"
      dm_key = Chat.generate_dm_key(user_a, user_b)
      {:ok, user_a: user_a, user_b: user_b, dm_key: dm_key}
    end

    test "creates a dm message", %{conn: conn, user_a: user_a, user_b: user_b, dm_key: dm_key} do
      conn =
        post(conn, ~p"/api/conversations/#{dm_key}/messages", %{
          "sender_id" => user_a,
          "text" => "ping"
        })

      assert %{"sender_id" => ^user_a, "recipient_id" => ^user_b, "text" => "ping"} =
               json_response(conn, 200)
    end

    test "creates broadcast message", %{conn: conn} do
      conn =
        post(conn, ~p"/api/conversations/broadcast/messages", %{
          "sender_id" => "admin:system",
          "text" => "announcement"
        })

      assert %{"sender_id" => "admin:system", "text" => "announcement"} =
               json_response(conn, 200)
    end

    test "rejects unauthorized sender", %{conn: conn, dm_key: dm_key} do
      conn =
        post(conn, ~p"/api/conversations/#{dm_key}/messages", %{
          "sender_id" => "user:mallory",
          "text" => "intrude"
        })

      assert %{"error" => "unauthorized"} = json_response(conn, 403)
    end
  end
end
