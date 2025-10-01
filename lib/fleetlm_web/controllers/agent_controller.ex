defmodule FleetlmWeb.AgentController do
  use FleetlmWeb, :controller

  alias Fleetlm.Agent

  action_fallback FleetlmWeb.FallbackController

  @doc """
  List all agents.
  Optional query param: ?status=enabled
  """
  def index(conn, %{"status" => status}) when status in ["enabled", "disabled"] do
    agents = Agent.list(status: status) |> Enum.map(&format_agent/1)
    json(conn, %{agents: agents})
  end

  def index(conn, _params) do
    agents = Agent.list() |> Enum.map(&format_agent/1)
    json(conn, %{agents: agents})
  end

  @doc """
  Get a single agent by ID.
  """
  def show(conn, %{"id" => id}) do
    case Agent.get(id) do
      {:ok, agent} ->
        json(conn, %{agent: format_agent(agent)})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Agent not found"})
    end
  end

  @doc """
  Create a new agent.
  """
  def create(conn, %{"agent" => agent_params}) do
    case Agent.create(agent_params) do
      {:ok, agent} ->
        conn
        |> put_status(:created)
        |> json(%{agent: format_agent(agent)})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: translate_errors(changeset)})
    end
  end

  @doc """
  Update an existing agent.
  """
  def update(conn, %{"id" => id, "agent" => agent_params}) do
    case Agent.update(id, agent_params) do
      {:ok, agent} ->
        json(conn, %{agent: format_agent(agent)})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Agent not found"})

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: translate_errors(changeset)})
    end
  end

  @doc """
  Delete (disable) an agent.
  """
  def delete(conn, %{"id" => id}) do
    case Agent.delete(id) do
      {:ok, agent} ->
        json(conn, %{agent: format_agent(agent), message: "Agent disabled"})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Agent not found"})
    end
  end

  # Helper to format agent for JSON response
  defp format_agent(agent) do
    %{
      id: agent.id,
      name: agent.name,
      origin_url: agent.origin_url,
      webhook_path: agent.webhook_path,
      message_history_mode: agent.message_history_mode,
      message_history_limit: agent.message_history_limit,
      timeout_ms: agent.timeout_ms,
      headers: agent.headers,
      status: agent.status,
      inserted_at: agent.inserted_at,
      updated_at: agent.updated_at
    }
  end

  # Helper to translate changeset errors to JSON
  defp translate_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
