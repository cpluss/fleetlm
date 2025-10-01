defmodule Fleetlm.AgentTest do
  use Fleetlm.StorageCase, async: true

  alias Fleetlm.Agent

  describe "create/1" do
    test "creates an agent with valid attributes" do
      attrs = %{
        id: "gpt-4-mini",
        name: "GPT-4 Mini",
        origin_url: "http://localhost:3000",
        webhook_path: "/webhook",
        message_history_mode: "tail",
        message_history_limit: 50,
        timeout_ms: 30_000
      }

      assert {:ok, agent} = Agent.create(attrs)
      assert agent.id == "gpt-4-mini"
      assert agent.name == "GPT-4 Mini"
      assert agent.origin_url == "http://localhost:3000"
      assert agent.webhook_path == "/webhook"
      assert agent.message_history_mode == "tail"
      assert agent.message_history_limit == 50
      assert agent.timeout_ms == 30_000
      assert agent.status == "enabled"
    end

    test "uses default values" do
      attrs = %{
        id: "claude-3",
        name: "Claude 3",
        origin_url: "http://localhost:4000"
      }

      assert {:ok, agent} = Agent.create(attrs)
      assert agent.webhook_path == "/webhook"
      assert agent.message_history_mode == "tail"
      assert agent.message_history_limit == 50
      assert agent.timeout_ms == 30_000
      assert agent.status == "enabled"
    end

    test "requires id, name, and origin_url" do
      assert {:error, changeset} = Agent.create(%{})
      assert "can't be blank" in errors_on(changeset).id
      assert "can't be blank" in errors_on(changeset).name
      assert "can't be blank" in errors_on(changeset).origin_url
    end

    test "validates message_history_mode" do
      attrs = %{
        id: "test-agent",
        name: "Test",
        origin_url: "http://localhost:3000",
        message_history_mode: "invalid"
      }

      assert {:error, changeset} = Agent.create(attrs)
      assert "is invalid" in errors_on(changeset).message_history_mode
    end

    test "validates status" do
      attrs = %{
        id: "test-agent",
        name: "Test",
        origin_url: "http://localhost:3000",
        status: "invalid"
      }

      assert {:error, changeset} = Agent.create(attrs)
      assert "is invalid" in errors_on(changeset).status
    end

    test "prevents duplicate IDs" do
      attrs = %{
        id: "duplicate-agent",
        name: "First",
        origin_url: "http://localhost:3000"
      }

      assert {:ok, _} = Agent.create(attrs)

      # Try to create again with same ID
      assert {:error, changeset} = Agent.create(attrs)
      assert "has already been taken" in errors_on(changeset).id
    end
  end

  describe "get/1" do
    test "retrieves an agent by ID" do
      agent = create_agent("test-agent")

      assert {:ok, fetched} = Agent.get("test-agent")
      assert fetched.id == agent.id
      assert fetched.name == agent.name
    end

    test "returns error for non-existent agent" do
      assert {:error, :not_found} = Agent.get("non-existent")
    end
  end

  describe "list/1" do
    test "lists all agents" do
      create_agent("agent-1")
      create_agent("agent-2")
      create_agent("agent-3")

      agents = Agent.list()
      assert length(agents) == 3
    end

    test "filters by status" do
      create_agent("enabled-1", %{status: "enabled"})
      create_agent("enabled-2", %{status: "enabled"})
      create_agent("disabled-1", %{status: "disabled"})

      enabled = Agent.list(status: "enabled")
      assert length(enabled) == 2
      assert Enum.all?(enabled, &(&1.status == "enabled"))

      disabled = Agent.list(status: "disabled")
      assert length(disabled) == 1
      assert hd(disabled).status == "disabled"
    end

    test "sorts by name" do
      create_agent("agent-c", %{name: "Charlie"})
      create_agent("agent-a", %{name: "Alice"})
      create_agent("agent-b", %{name: "Bob"})

      agents = Agent.list()
      names = Enum.map(agents, & &1.name)
      assert names == ["Alice", "Bob", "Charlie"]
    end
  end

  describe "update/2" do
    test "updates an agent" do
      agent = create_agent("test-agent")

      assert {:ok, updated} = Agent.update(agent.id, %{name: "Updated Name"})
      assert updated.name == "Updated Name"
      assert updated.id == agent.id
    end

    test "can update message history mode" do
      agent = create_agent("test-agent")

      assert {:ok, updated} = Agent.update(agent.id, %{message_history_mode: "entire"})
      assert updated.message_history_mode == "entire"
    end

    test "returns error for non-existent agent" do
      assert {:error, :not_found} = Agent.update("non-existent", %{name: "Test"})
    end

    test "validates updated values" do
      agent = create_agent("test-agent")

      assert {:error, changeset} = Agent.update(agent.id, %{message_history_mode: "invalid"})
      assert "is invalid" in errors_on(changeset).message_history_mode
    end
  end

  describe "delete/1" do
    test "soft deletes an agent by setting status to disabled" do
      agent = create_agent("test-agent")
      assert agent.status == "enabled"

      assert {:ok, deleted} = Agent.delete(agent.id)
      assert deleted.status == "disabled"

      # Agent still exists in database
      assert {:ok, fetched} = Agent.get(agent.id)
      assert fetched.status == "disabled"
    end

    test "returns error for non-existent agent" do
      assert {:error, :not_found} = Agent.delete("non-existent")
    end
  end

  describe "enabled?/1" do
    test "returns true for enabled agents" do
      agent = create_agent("test-agent", %{status: "enabled"})
      assert Agent.enabled?(agent.id)
    end

    test "returns false for disabled agents" do
      agent = create_agent("test-agent", %{status: "disabled"})
      refute Agent.enabled?(agent.id)
    end

    test "returns false for non-existent agents" do
      refute Agent.enabled?("non-existent")
    end
  end

  describe "message history modes" do
    test "tail mode with custom limit" do
      attrs = %{
        id: "tail-agent",
        name: "Tail Agent",
        origin_url: "http://localhost:3000",
        message_history_mode: "tail",
        message_history_limit: 100
      }

      assert {:ok, agent} = Agent.create(attrs)
      assert agent.message_history_mode == "tail"
      assert agent.message_history_limit == 100
    end

    test "entire mode" do
      attrs = %{
        id: "entire-agent",
        name: "Entire Agent",
        origin_url: "http://localhost:3000",
        message_history_mode: "entire"
      }

      assert {:ok, agent} = Agent.create(attrs)
      assert agent.message_history_mode == "entire"
    end

    test "last mode" do
      attrs = %{
        id: "last-agent",
        name: "Last Agent",
        origin_url: "http://localhost:3000",
        message_history_mode: "last"
      }

      assert {:ok, agent} = Agent.create(attrs)
      assert agent.message_history_mode == "last"
    end
  end

  # Test helpers

  defp create_agent(id, attrs \\ %{}) do
    default_attrs = %{
      id: id,
      name: "Test Agent #{id}",
      origin_url: "http://localhost:3000"
    }

    {:ok, agent} = Agent.create(Map.merge(default_attrs, attrs))
    agent
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
