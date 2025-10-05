defmodule Fleetlm.Agent.WebhookIntegrationTest do
  use Fleetlm.TestCase

  alias Fleetlm.Agent
  alias Fleetlm.Runtime.Router
  alias Fleetlm.Storage, as: StorageAPI

  require ExUnit.CaptureLog

  setup do
    # Enable webhooks for this test (disabled globally in test_helper)
    Application.put_env(:fleetlm, :disable_agent_webhooks, false)

    # Start Bypass mock server
    bypass = Bypass.open()

    # Create test agent pointing to Bypass
    {:ok, agent} =
      Agent.create(%{
        id: "echo-agent",
        name: "Echo Agent",
        origin_url: "http://127.0.0.1:#{bypass.port}",
        webhook_path: "/webhook",
        message_history_mode: "tail",
        message_history_limit: 50,
        debounce_window_ms: 0,
        timeout_ms: 5000
      })

    # Create session
    {:ok, session} = StorageAPI.create_session("alice", "echo-agent", %{})

    on_exit(fn ->
      Application.put_env(:fleetlm, :disable_agent_webhooks, true)
      Fleetlm.Agent.Cache.clear_all()
      Bypass.down(bypass)
    end)

    %{agent: agent, session: session, bypass: bypass}
  end

  describe "end-to-end webhook flow" do
    test "user message triggers agent webhook and response is appended", %{
      session: session,
      bypass: bypass
    } do
      # Set up Bypass BEFORE sending message (stub is replaced by expect)
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/webhook", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(body)

        # Send payload to test for verification
        send(test_pid, {:webhook_called, payload})

        # Return agent response
        response =
          Jason.encode!(%{"kind" => "text", "content" => %{"text" => "Hello back from agent!"}}) <>
            "\n"

        Plug.Conn.resp(conn, 200, response)
      end)

      # User sends message via Router
      {:ok, user_msg} =
        Router.append_message(
          session.id,
          "alice",
          "text",
          %{"text" => "Hello agent!"},
          %{}
        )

      assert user_msg.sender_id == "alice"
      assert user_msg.seq == 1

      # Wait for webhook to be called
      assert_receive {:webhook_called, payload}, 2000

      # Verify webhook payload
      assert payload["session_id"] == session.id
      assert payload["agent_id"] == "echo-agent"
      assert payload["user_id"] == "alice"
      assert length(payload["messages"]) == 1
      assert hd(payload["messages"])["content"]["text"] == "Hello agent!"

      # Wait for agent response to be appended
      assert_message_count(session.id, 2)

      # Verify agent response was appended
      {:ok, messages} = StorageAPI.get_messages(session.id, 0, 100)

      [_user_msg, agent_msg] = messages
      assert agent_msg.sender_id == "echo-agent"
      assert agent_msg.seq == 2
      assert agent_msg.content["text"] == "Hello back from agent!"
    end

    test "multiple user messages trigger multiple webhooks", %{session: session, bypass: bypass} do
      # Set up Bypass to respond to all webhook calls
      Bypass.expect(bypass, "POST", "/webhook", fn conn ->
        {:ok, _body, conn} = Plug.Conn.read_body(conn)

        response =
          Jason.encode!(%{"kind" => "text", "content" => %{"text" => "Echo response"}}) <> "\n"

        Plug.Conn.resp(conn, 200, response)
      end)

      # Send first message
      {:ok, _} = Router.append_message(session.id, "alice", "text", %{"text" => "Message 1"}, %{})
      assert_message_count(session.id, 2)

      # Send second message
      {:ok, _} = Router.append_message(session.id, "alice", "text", %{"text" => "Message 2"}, %{})
      assert_message_count(session.id, 4)

      # Send third message
      {:ok, _} = Router.append_message(session.id, "alice", "text", %{"text" => "Message 3"}, %{})
      assert_message_count(session.id, 6)

      # Should have 6 messages: 3 user + 3 agent responses
      {:ok, messages} = StorageAPI.get_messages(session.id, 0, 100)
      assert length(messages) == 6

      # Verify alternating pattern
      assert Enum.at(messages, 0).sender_id == "alice"
      assert Enum.at(messages, 1).sender_id == "echo-agent"
      assert Enum.at(messages, 2).sender_id == "alice"
      assert Enum.at(messages, 3).sender_id == "echo-agent"
      assert Enum.at(messages, 4).sender_id == "alice"
      assert Enum.at(messages, 5).sender_id == "echo-agent"
    end

    test "agent messages do not trigger webhooks", %{session: session, bypass: bypass} do
      webhook_count = :counters.new(1, [])

      Bypass.expect_once(bypass, "POST", "/webhook", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        _payload = Jason.decode!(body)

        :counters.add(webhook_count, 1, 1)

        response =
          Jason.encode!(%{"kind" => "text", "content" => %{"text" => "Response"}}) <> "\n"

        Plug.Conn.resp(conn, 200, response)
      end)

      # User message triggers webhook
      {:ok, _} = Router.append_message(session.id, "alice", "text", %{"text" => "User msg"}, %{})
      assert_message_count(session.id, 2)

      # Agent's response should NOT trigger another webhook
      Process.sleep(500)

      # Should have exactly 1 webhook call
      assert :counters.get(webhook_count, 1) == 1

      # Should only have 2 messages
      {:ok, messages} = StorageAPI.get_messages(session.id, 0, 100)
      assert length(messages) == 2
    end

    test "webhook includes message history in order", %{session: session, bypass: bypass} do
      test_pid = self()
      call_count = :counters.new(1, [])

      Bypass.expect(bypass, "POST", "/webhook", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(body)

        call_num = :counters.get(call_count, 1) + 1
        :counters.put(call_count, 1, call_num)

        send(test_pid, {:webhook_call, call_num, payload})

        response_text = if call_num == 1, do: "First response", else: "Second response"

        response =
          Jason.encode!(%{"kind" => "text", "content" => %{"text" => response_text}}) <> "\n"

        Plug.Conn.resp(conn, 200, response)
      end)

      # Send initial message and let agent respond
      {:ok, _} = Router.append_message(session.id, "alice", "text", %{"text" => "First"}, %{})
      assert_receive {:webhook_call, 1, _}, 2000
      assert_message_count(session.id, 2)

      # Send second message - webhook should include history
      {:ok, _} = Router.append_message(session.id, "alice", "text", %{"text" => "Second"}, %{})
      assert_receive {:webhook_call, 2, payload}, 2000

      # Should have 3 messages in history: user1, agent1, user2
      assert length(payload["messages"]) == 3
      assert Enum.at(payload["messages"], 0)["content"]["text"] == "First"
      assert Enum.at(payload["messages"], 1)["content"]["text"] == "First response"
      assert Enum.at(payload["messages"], 2)["content"]["text"] == "Second"
    end

    test "disabled agent does not receive webhooks", %{session: _session, bypass: bypass} do
      # Allow any requests to the shared bypass (from echo-agent if any)
      Bypass.pass(bypass)

      ExUnit.CaptureLog.capture_log(fn ->
        # Create disabled agent
        {:ok, _disabled_agent} =
          Agent.create(%{
            id: "disabled-agent",
            name: "Disabled",
            origin_url: "http://localhost:3000",
            status: "disabled"
          })

        # Create session with disabled agent
        {:ok, disabled_session} =
          StorageAPI.create_session("alice", "disabled-agent", %{})

        # Send message
        {:ok, _} =
          Router.append_message(
            disabled_session.id,
            "alice",
            "text",
            %{"text" => "Hello"},
            %{}
          )

        # Should not receive webhook
        refute_receive {:agent_webhook_called, _}, 1000

        # Only user message should exist
        {:ok, messages} = StorageAPI.get_messages(disabled_session.id, 0, 100)
        assert length(messages) == 1
      end)
    end
  end

  describe "error handling" do
    test "handles agent returning invalid response", %{session: session, bypass: bypass} do
      Bypass.expect(bypass, "POST", "/webhook", fn conn ->
        {:ok, _body, conn} = Plug.Conn.read_body(conn)

        # Return invalid JSON (missing required fields)
        response = "{\"invalid\": \"response\"}\n"
        Plug.Conn.resp(conn, 200, response)
      end)

      ExUnit.CaptureLog.capture_log(fn ->
        {:ok, _} = Router.append_message(session.id, "alice", "text", %{"text" => "Hello"}, %{})
        Process.sleep(1000)
      end)

      # Should only have user message (agent response failed to parse)
      {:ok, messages} = StorageAPI.get_messages(session.id, 0, 100)
      assert length(messages) == 1
    end

    test "handles agent returning empty response", %{session: session, bypass: bypass} do
      Bypass.expect(bypass, "POST", "/webhook", fn conn ->
        {:ok, _body, conn} = Plug.Conn.read_body(conn)

        # Return valid response with empty content
        response = Jason.encode!(%{"kind" => "text", "content" => %{"text" => ""}}) <> "\n"
        Plug.Conn.resp(conn, 200, response)
      end)

      {:ok, _} = Router.append_message(session.id, "alice", "text", %{"text" => "Hello"}, %{})
      assert_message_count(session.id, 2)

      # Message should be appended even with empty content
      {:ok, messages} = StorageAPI.get_messages(session.id, 0, 100)
      assert length(messages) == 2
    end
  end

  defp assert_message_count(session_id, expected) do
    eventually(fn ->
      {:ok, messages} = StorageAPI.get_messages(session_id, 0, 100)
      assert length(messages) == expected
    end)
  end
end
