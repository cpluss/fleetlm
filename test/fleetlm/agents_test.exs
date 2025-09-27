defmodule Fleetlm.AgentTest do
  use Fleetlm.DataCase, async: false

  alias Fleetlm.Agent
  alias Fleetlm.Agent.AgentEndpoint
  alias Fleetlm.Conversation.Participants
  alias Fleetlm.Conversation

  setup do
    {:ok, participant} =
      Participants.upsert_participant(%{
        id: "agent:test",
        kind: "agent",
        display_name: "Test Agent"
      })

    %{agent: participant}
  end

  test "upsert_agent creates participant and endpoint", %{agent: agent} do
    {:ok, %{participant: participant, endpoint: endpoint}} =
      Agent.upsert_agent(%{
        id: agent.id,
        display_name: "Test Agent",
        endpoint: %{
          origin_url: "https://example.com/webhook",
          auth_strategy: "none"
        }
      })

    assert participant.id == agent.id
    assert %AgentEndpoint{origin_url: "https://example.com/webhook"} = endpoint
  end

  test "get_endpoint returns stored endpoint", %{agent: agent} do
    Agent.upsert_endpoint!(agent.id, %{origin_url: "https://example.com", auth_strategy: "none"})

    assert %AgentEndpoint{origin_url: "https://example.com"} = Agent.get_endpoint(agent.id)
  end

  describe "dispatcher" do
    setup %{agent: agent} do
      {:ok, _} =
        Participants.upsert_participant(%{
          id: "user:alice",
          kind: "user",
          display_name: "Alice"
        })

      previous = Application.get_env(:fleetlm, :agent_dispatcher)
      Application.put_env(:fleetlm, :agent_dispatcher, %{mode: :test, pid: self()})

      on_exit(fn ->
        if previous do
          Application.put_env(:fleetlm, :agent_dispatcher, previous)
        else
          Application.delete_env(:fleetlm, :agent_dispatcher)
        end
      end)

      %{agent: agent}
    end

    test "dispatches user messages to agent endpoint", %{agent: agent} do
      Agent.upsert_endpoint!(agent.id, %{
        origin_url: "https://example.com",
        auth_strategy: "none"
      })

      {:ok, session} =
        Conversation.start_session(%{
          initiator_id: "user:alice",
          peer_id: agent.id
        })

      {:ok, message} =
        Conversation.append_message(session.id, %{
          sender_id: "user:alice",
          kind: "text",
          content: %{text: "hello"}
        })

      assert_receive {:agent_dispatch, payload}
      assert payload["session"]["id"] == session.id
      assert payload["message"]["id"] == message.id

      # In test mode with agent_dispatcher config, delivery logs are not created
      # since the webhook delivery is mocked. This is expected behavior.
    end

    test "does not dispatch messages sent by the agent", %{agent: agent} do
      Agent.upsert_endpoint!(agent.id, %{
        origin_url: "https://example.com",
        auth_strategy: "none"
      })

      {:ok, session} =
        Conversation.start_session(%{
          initiator_id: agent.id,
          peer_id: "user:alice"
        })

      {:ok, _message} =
        Conversation.append_message(session.id, %{
          sender_id: agent.id,
          kind: "text",
          content: %{text: "ping"}
        })

      refute_receive {:agent_dispatch, _}, 100
    end
  end
end
