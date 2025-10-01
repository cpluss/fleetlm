defmodule Fleetlm.Agent.WebhookIntegrationTest do
  use Fleetlm.StorageCase, async: false

  alias Fleetlm.Agent
  alias Fleetlm.Runtime.Router
  alias FleetLM.Storage.API, as: StorageAPI

  setup do
    # Enable webhooks for this test suite
    Application.put_env(:fleetlm, :disable_agent_webhooks, false)

    # Enable test mode for agent webhooks
    setup_test_mode(self())

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
      cleanup_test_mode()
      Application.put_env(:fleetlm, :disable_agent_webhooks, true)
    end)

    %{agent: agent, session: session}
  end

  describe "end-to-end webhook flow" do
    test "user message triggers agent webhook and response is appended", %{session: session} do
      # Setup agent response handler
      agent_responses = agent_response_queue()

      queue_agent_response(agent_responses, %{
        "kind" => "text",
        "content" => %{"text" => "Hello back from agent!"}
      })

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

      # Wait for async webhook dispatch and response
      assert_receive {:agent_webhook_called, payload}, 2000

      # Verify webhook payload (uses atom keys)
      assert payload.session_id == session.id
      assert payload.agent_id == "echo-agent"
      assert payload.user_id == "alice"
      assert length(payload.messages) == 1
      assert hd(payload.messages).content["text"] == "Hello agent!"

      # Wait a bit for agent response to be appended
      Process.sleep(300)

      # Verify agent response was appended
      {:ok, messages} = StorageAPI.get_messages(session.id, 0, 100)
      assert length(messages) == 2

      [_user_msg, agent_msg] = messages
      assert agent_msg.sender_id == "echo-agent"
      assert agent_msg.seq == 2
      assert agent_msg.content["text"] == "Hello back from agent!"
    end

    test "multiple user messages trigger multiple webhooks", %{session: session} do
      agent_responses = agent_response_queue()

      queue_agent_response(agent_responses, %{
        "kind" => "text",
        "content" => %{"text" => "Response 1"}
      })

      queue_agent_response(agent_responses, %{
        "kind" => "text",
        "content" => %{"text" => "Response 2"}
      })

      queue_agent_response(agent_responses, %{
        "kind" => "text",
        "content" => %{"text" => "Response 3"}
      })

      # Send multiple messages
      {:ok, _} = Router.append_message(session.id, "alice", "text", %{"text" => "Message 1"}, %{})
      assert_receive {:agent_webhook_called, _}, 2000

      {:ok, _} = Router.append_message(session.id, "alice", "text", %{"text" => "Message 2"}, %{})
      assert_receive {:agent_webhook_called, _}, 2000

      {:ok, _} = Router.append_message(session.id, "alice", "text", %{"text" => "Message 3"}, %{})
      assert_receive {:agent_webhook_called, _}, 2000

      Process.sleep(500)

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
      agent_responses = agent_response_queue()

      queue_agent_response(agent_responses, %{
        "kind" => "text",
        "content" => %{"text" => "Response"}
      })

      # User message triggers webhook
      {:ok, _} = Router.append_message(session.id, "alice", "text", %{"text" => "User msg"}, %{})
      assert_receive {:agent_webhook_called, _}, 2000

      Process.sleep(300)

      # Agent's response should NOT trigger another webhook
      refute_receive {:agent_webhook_called, _}, 1000

      # Should only have 2 messages
      {:ok, messages} = StorageAPI.get_messages(session.id, 0, 100)
      assert length(messages) == 2
    end

    test "webhook includes message history in order", %{session: session} do
      agent_responses = agent_response_queue()

      # Send initial message and let agent respond
      queue_agent_response(agent_responses, %{
        "kind" => "text",
        "content" => %{"text" => "First response"}
      })

      {:ok, _} = Router.append_message(session.id, "alice", "text", %{"text" => "First"}, %{})
      assert_receive {:agent_webhook_called, _}, 2000
      Process.sleep(300)

      # Send second message - webhook should include history
      queue_agent_response(agent_responses, %{
        "kind" => "text",
        "content" => %{"text" => "Second response"}
      })

      {:ok, _} = Router.append_message(session.id, "alice", "text", %{"text" => "Second"}, %{})
      assert_receive {:agent_webhook_called, payload}, 2000

      # Should have 3 messages in history: user1, agent1, user2
      assert length(payload.messages) == 3
      assert Enum.at(payload.messages, 0).content["text"] == "First"
      assert Enum.at(payload.messages, 1).content["text"] == "First response"
      assert Enum.at(payload.messages, 2).content["text"] == "Second"
    end

    test "disabled agent does not receive webhooks", %{session: _session} do
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
    end
  end

  describe "error handling" do
    test "handles agent returning invalid response", %{session: session} do
      agent_responses = agent_response_queue()

      # Queue invalid response (missing required fields)
      queue_agent_response(agent_responses, %{
        "invalid" => "response"
      })

      {:ok, _} = Router.append_message(session.id, "alice", "text", %{"text" => "Hello"}, %{})
      assert_receive {:agent_webhook_called, _}, 2000

      Process.sleep(300)

      # Should only have user message (agent response failed)
      {:ok, messages} = StorageAPI.get_messages(session.id, 0, 100)
      assert length(messages) == 1
    end

    test "handles agent returning empty response", %{session: session} do
      agent_responses = agent_response_queue()

      # Queue empty string
      :ets.insert(agent_responses, {:response, ""})

      {:ok, _} = Router.append_message(session.id, "alice", "text", %{"text" => "Hello"}, %{})
      assert_receive {:agent_webhook_called, _}, 2000

      Process.sleep(300)

      {:ok, messages} = StorageAPI.get_messages(session.id, 0, 100)
      assert length(messages) == 1
    end
  end

  # Test mode helpers

  defp setup_test_mode(test_pid) do
    # Store test PID for webhook worker to send messages to
    Application.put_env(:fleetlm, :agent_webhook_test_mode, %{
      enabled: true,
      test_pid: test_pid
    })
  end

  defp cleanup_test_mode do
    Application.delete_env(:fleetlm, :agent_webhook_test_mode)
  end

  defp agent_response_queue do
    :ets.new(:agent_responses, [:ordered_set, :public, :named_table])
  end

  defp queue_agent_response(_table, response) do
    # Use timestamp as key to maintain order
    key = System.monotonic_time()
    :ets.insert(:agent_responses, {key, response})
  end
end
