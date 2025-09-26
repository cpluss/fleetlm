defmodule Fleetlm.AgentsTest do
  use Fleetlm.DataCase, async: true

  alias Fleetlm.Agents
  alias Fleetlm.Agents.AgentEndpoint
  alias Fleetlm.Participants

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
      Agents.upsert_agent(%{
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
    Agents.upsert_endpoint!(agent.id, %{origin_url: "https://example.com", auth_strategy: "none"})

    assert %AgentEndpoint{origin_url: "https://example.com"} = Agents.get_endpoint(agent.id)
  end
end
