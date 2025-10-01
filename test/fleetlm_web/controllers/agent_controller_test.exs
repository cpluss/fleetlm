defmodule FleetlmWeb.AgentControllerTest do
  use Fleetlm.TestCase, mode: :conn

  alias Fleetlm.Agent

  describe "GET /api/agents" do
    test "returns empty list when no agents exist", %{conn: conn} do
      conn = get(conn, ~p"/api/agents")

      assert json_response(conn, 200) == %{"agents" => []}
    end

    test "returns list of agents", %{conn: conn} do
      create_agent("agent-1", %{name: "Agent 1"})
      create_agent("agent-2", %{name: "Agent 2"})

      conn = get(conn, ~p"/api/agents")
      response = json_response(conn, 200)

      assert length(response["agents"]) == 2
      assert Enum.any?(response["agents"], &(&1["id"] == "agent-1"))
      assert Enum.any?(response["agents"], &(&1["id"] == "agent-2"))
    end

    test "filters by status", %{conn: conn} do
      create_agent("enabled-1", %{status: "enabled"})
      create_agent("disabled-1", %{status: "disabled"})

      conn = get(conn, ~p"/api/agents?status=enabled")
      response = json_response(conn, 200)

      assert length(response["agents"]) == 1
      assert hd(response["agents"])["status"] == "enabled"
    end
  end

  describe "GET /api/agents/:id" do
    test "returns agent by ID", %{conn: conn} do
      agent = create_agent("test-agent", %{name: "Test Agent"})

      conn = get(conn, ~p"/api/agents/#{agent.id}")
      response = json_response(conn, 200)

      assert response["agent"]["id"] == "test-agent"
      assert response["agent"]["name"] == "Test Agent"
      assert response["agent"]["origin_url"] == "http://localhost:3000"
    end

    test "returns 404 for non-existent agent", %{conn: conn} do
      conn = get(conn, ~p"/api/agents/non-existent")

      assert json_response(conn, 404) == %{"error" => "Agent not found"}
    end
  end

  describe "POST /api/agents" do
    test "creates agent with valid params", %{conn: conn} do
      params = %{
        "agent" => %{
          "id" => "new-agent",
          "name" => "New Agent",
          "origin_url" => "http://localhost:4000",
          "webhook_path" => "/webhook",
          "message_history_mode" => "tail",
          "message_history_limit" => 100
        }
      }

      conn = post(conn, ~p"/api/agents", params)
      response = json_response(conn, 201)

      assert response["agent"]["id"] == "new-agent"
      assert response["agent"]["name"] == "New Agent"
      assert response["agent"]["origin_url"] == "http://localhost:4000"
      assert response["agent"]["message_history_limit"] == 100
    end

    test "creates agent with minimal params (uses defaults)", %{conn: conn} do
      params = %{
        "agent" => %{
          "id" => "minimal-agent",
          "name" => "Minimal",
          "origin_url" => "http://localhost:3000"
        }
      }

      conn = post(conn, ~p"/api/agents", params)
      response = json_response(conn, 201)

      assert response["agent"]["id"] == "minimal-agent"
      assert response["agent"]["webhook_path"] == "/webhook"
      assert response["agent"]["message_history_mode"] == "tail"
      assert response["agent"]["message_history_limit"] == 50
      assert response["agent"]["timeout_ms"] == 30_000
      assert response["agent"]["status"] == "enabled"
    end

    test "returns 422 with validation errors", %{conn: conn} do
      params = %{
        "agent" => %{
          "name" => "Missing ID"
        }
      }

      conn = post(conn, ~p"/api/agents", params)
      response = json_response(conn, 422)

      assert Map.has_key?(response, "errors")
      assert Map.has_key?(response["errors"], "id")
      assert Map.has_key?(response["errors"], "origin_url")
    end

    test "returns 422 for invalid message_history_mode", %{conn: conn} do
      params = %{
        "agent" => %{
          "id" => "invalid-agent",
          "name" => "Invalid",
          "origin_url" => "http://localhost:3000",
          "message_history_mode" => "invalid_mode"
        }
      }

      conn = post(conn, ~p"/api/agents", params)
      response = json_response(conn, 422)

      assert Map.has_key?(response["errors"], "message_history_mode")
    end
  end

  describe "PUT /api/agents/:id" do
    test "updates agent", %{conn: conn} do
      agent = create_agent("test-agent")

      params = %{
        "agent" => %{
          "name" => "Updated Name",
          "message_history_mode" => "entire"
        }
      }

      conn = put(conn, ~p"/api/agents/#{agent.id}", params)
      response = json_response(conn, 200)

      assert response["agent"]["name"] == "Updated Name"
      assert response["agent"]["message_history_mode"] == "entire"
      # Other fields unchanged
      assert response["agent"]["origin_url"] == agent.origin_url
    end

    test "returns 404 for non-existent agent", %{conn: conn} do
      params = %{"agent" => %{"name" => "New Name"}}

      conn = put(conn, ~p"/api/agents/non-existent", params)

      assert json_response(conn, 404) == %{"error" => "Agent not found"}
    end

    test "returns 422 for invalid updates", %{conn: conn} do
      agent = create_agent("test-agent")

      params = %{
        "agent" => %{
          "message_history_mode" => "invalid"
        }
      }

      conn = put(conn, ~p"/api/agents/#{agent.id}", params)
      response = json_response(conn, 422)

      assert Map.has_key?(response["errors"], "message_history_mode")
    end
  end

  describe "DELETE /api/agents/:id" do
    test "disables agent (soft delete)", %{conn: conn} do
      agent = create_agent("test-agent")
      assert agent.status == "enabled"

      conn = delete(conn, ~p"/api/agents/#{agent.id}")
      response = json_response(conn, 200)

      assert response["agent"]["status"] == "disabled"
      assert response["message"] == "Agent disabled"

      # Verify agent still exists but is disabled
      {:ok, fetched} = Agent.get(agent.id)
      assert fetched.status == "disabled"
    end

    test "returns 404 for non-existent agent", %{conn: conn} do
      conn = delete(conn, ~p"/api/agents/non-existent")

      assert json_response(conn, 404) == %{"error" => "Agent not found"}
    end
  end

  describe "REST resource routes" do
    test "all standard routes are available", %{conn: conn} do
      # Create
      conn =
        post(conn, ~p"/api/agents", %{
          "agent" => %{
            "id" => "rest-test",
            "name" => "REST Test",
            "origin_url" => "http://localhost:3000"
          }
        })

      assert conn.status == 201

      # List
      conn = get(conn, ~p"/api/agents")
      assert conn.status == 200

      # Show
      conn = get(conn, ~p"/api/agents/rest-test")
      assert conn.status == 200

      # Update
      conn =
        put(conn, ~p"/api/agents/rest-test", %{
          "agent" => %{"name" => "Updated"}
        })

      assert conn.status == 200

      # Delete
      conn = delete(conn, ~p"/api/agents/rest-test")
      assert conn.status == 200
    end
  end

  # Helper functions

  defp create_agent(id, attrs \\ %{}) do
    default_attrs = %{
      id: id,
      name: "Test Agent #{id}",
      origin_url: "http://localhost:3000"
    }

    {:ok, agent} = Agent.create(Map.merge(default_attrs, attrs))
    agent
  end
end
