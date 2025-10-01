defmodule Fleetlm.Agent.WebhookIntegrationTest do
  use Fleetlm.TestCase

  alias Fleetlm.Agent
  alias Fleetlm.Runtime.Router
  alias FleetLM.Storage.API, as: StorageAPI

  require ExUnit.CaptureLog

  setup do
    # Enable webhooks for this test (disabled globally in test_helper)
    Application.put_env(:fleetlm, :disable_agent_webhooks, false)

    # Register test PID for the test plug
    Application.put_env(:fleetlm, :agent_test_pid, self())

    # Configure application to use test plug adapter (no streaming with plug)
    Application.put_env(:fleetlm, :agent_req_opts, plug: Fleetlm.Agent.TestPlug, into: nil)

    # Create test agent
    {:ok, agent} =
      Agent.create(%{
        id: "echo-agent",
        name: "Echo Agent",
        origin_url: "http://localhost:3000",
        webhook_path: "/webhook",
        message_history_mode: "tail",
        message_history_limit: 50
      })

    # Create session
    {:ok, session} = StorageAPI.create_session("alice", "echo-agent", %{})

    on_exit(fn ->
      Application.put_env(:fleetlm, :disable_agent_webhooks, true)
      Application.delete_env(:fleetlm, :agent_req_opts)
      Application.delete_env(:fleetlm, :agent_test_pid)
    end)

    %{agent: agent, session: session}
  end

  describe "end-to-end webhook flow" do
    test "user message triggers agent webhook and response is appended", %{session: session} do
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

      # Wait for async webhook dispatch
      assert_receive {:agent_webhook_called, payload, plug_pid}, 2000

      # Verify webhook payload
      assert payload["session_id"] == session.id
      assert payload["agent_id"] == "echo-agent"
      assert payload["user_id"] == "alice"
      assert length(payload["messages"]) == 1
      assert hd(payload["messages"])["content"]["text"] == "Hello agent!"

      # Send agent response back to the plug process
      send(plug_pid, {
        :agent_response,
        %{"kind" => "text", "content" => %{"text" => "Hello back from agent!"}}
      })

      # Wait for agent response to be appended
      assert_message_count(session.id, 2)

      # Verify agent response was appended
      {:ok, messages} = StorageAPI.get_messages(session.id, 0, 100)

      [_user_msg, agent_msg] = messages
      assert agent_msg.sender_id == "echo-agent"
      assert agent_msg.seq == 2
      assert agent_msg.content["text"] == "Hello back from agent!"
    end

    test "multiple user messages trigger multiple webhooks", %{session: session} do
      # Send first message
      {:ok, _} = Router.append_message(session.id, "alice", "text", %{"text" => "Message 1"}, %{})
      assert_receive {:agent_webhook_called, _, plug_pid}, 2000

      send(plug_pid, {
        :agent_response,
        %{"kind" => "text", "content" => %{"text" => "Response 1"}}
      })

      assert_message_count(session.id, 2)

      # Send second message
      {:ok, _} = Router.append_message(session.id, "alice", "text", %{"text" => "Message 2"}, %{})
      assert_receive {:agent_webhook_called, _, plug_pid}, 2000

      send(plug_pid, {
        :agent_response,
        %{"kind" => "text", "content" => %{"text" => "Response 2"}}
      })

      assert_message_count(session.id, 4)

      # Send third message
      {:ok, _} = Router.append_message(session.id, "alice", "text", %{"text" => "Message 3"}, %{})
      assert_receive {:agent_webhook_called, _, plug_pid}, 2000

      send(plug_pid, {
        :agent_response,
        %{"kind" => "text", "content" => %{"text" => "Response 3"}}
      })

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

    test "agent messages do not trigger webhooks", %{session: session} do
      # User message triggers webhook
      {:ok, _} = Router.append_message(session.id, "alice", "text", %{"text" => "User msg"}, %{})
      assert_receive {:agent_webhook_called, _, plug_pid}, 2000

      send(plug_pid, {
        :agent_response,
        %{"kind" => "text", "content" => %{"text" => "Response"}}
      })

      assert_message_count(session.id, 2)

      # Agent's response should NOT trigger another webhook
      refute_receive {:agent_webhook_called, _, _}, 1000

      # Should only have 2 messages
      {:ok, messages} = StorageAPI.get_messages(session.id, 0, 100)
      assert length(messages) == 2
    end

    test "webhook includes message history in order", %{session: session} do
      # Send initial message and let agent respond
      {:ok, _} = Router.append_message(session.id, "alice", "text", %{"text" => "First"}, %{})
      assert_receive {:agent_webhook_called, _, plug_pid}, 2000

      send(plug_pid, {
        :agent_response,
        %{"kind" => "text", "content" => %{"text" => "First response"}}
      })

      assert_message_count(session.id, 2)

      # Send second message - webhook should include history
      {:ok, _} = Router.append_message(session.id, "alice", "text", %{"text" => "Second"}, %{})
      assert_receive {:agent_webhook_called, payload, plug_pid}, 2000

      # Should have 3 messages in history: user1, agent1, user2
      assert length(payload["messages"]) == 3
      assert Enum.at(payload["messages"], 0)["content"]["text"] == "First"
      assert Enum.at(payload["messages"], 1)["content"]["text"] == "First response"
      assert Enum.at(payload["messages"], 2)["content"]["text"] == "Second"

      send(plug_pid, {
        :agent_response,
        %{"kind" => "text", "content" => %{"text" => "Second response"}}
      })
    end

    test "disabled agent does not receive webhooks", %{session: _session} do
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
    test "handles agent returning invalid response", %{session: session} do
      ExUnit.CaptureLog.capture_log(fn ->
        {:ok, _} = Router.append_message(session.id, "alice", "text", %{"text" => "Hello"}, %{})
        assert_receive {:agent_webhook_called, _, plug_pid}, 2000

        send(plug_pid, {
          :agent_response,
          %{"invalid" => "response"}
        })

        assert_message_count(session.id, 1)
      end)

      # Should only have user message (agent response failed)
      {:ok, messages} = StorageAPI.get_messages(session.id, 0, 100)
      assert length(messages) == 1
    end

    test "handles agent returning empty response", %{session: session} do
      ExUnit.CaptureLog.capture_log(fn ->
        {:ok, _} = Router.append_message(session.id, "alice", "text", %{"text" => "Hello"}, %{})
        assert_receive {:agent_webhook_called, _, plug_pid}, 2000

        send(plug_pid, {
          :agent_response,
          %{"kind" => "text", "content" => ""}
        })

        assert_message_count(session.id, 2)
      end)

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
