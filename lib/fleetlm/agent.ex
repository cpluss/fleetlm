defmodule Fleetlm.Agent do
  @moduledoc """
  Agent context for managing external AI agent endpoints.

  Agents are stateless HTTP endpoints that receive message history
  and return responses synchronously.
  """

  import Ecto.Query

  alias Fleetlm.Repo
  alias Fleetlm.Agent.Schema

  @type t :: Schema.t()

  ## Public API

  @doc """
  Create a new agent.
  """
  @spec create(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    %Schema{}
    |> Schema.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Get an agent by ID.
  """
  @spec get(String.t()) :: {:ok, t()} | {:error, :not_found}
  def get(id) when is_binary(id) do
    case Repo.get(Schema, id) do
      nil -> {:error, :not_found}
      agent -> {:ok, agent}
    end
  end

  @doc """
  Get agent without error tuple (raises if not found).
  """
  @spec get!(String.t()) :: t()
  def get!(id) when is_binary(id) do
    Repo.get!(Schema, id)
  end

  @doc """
  List all agents with optional filters.

  ## Options
  - `:status` - Filter by status ("enabled" | "disabled")
  """
  @spec list(keyword()) :: [t()]
  def list(opts \\ []) do
    query = from(a in Schema, order_by: [asc: a.name])

    query =
      case Keyword.get(opts, :status) do
        nil -> query
        status -> where(query, [a], a.status == ^status)
      end

    Repo.all(query)
  end

  @doc """
  Update an agent.
  Invalidates cache after successful update.
  """
  @spec update(String.t(), map()) :: {:ok, t()} | {:error, Ecto.Changeset.t() | :not_found}
  def update(id, attrs) do
    case get(id) do
      {:ok, agent} ->
        case agent
             |> Schema.changeset(attrs)
             |> Repo.update() do
          {:ok, _updated_agent} = result ->
            Fleetlm.Agent.Cache.invalidate(id)
            result

          error ->
            error
        end

      {:error, :not_found} = error ->
        error
    end
  end

  @doc """
  Delete (disable) an agent.
  Soft delete by setting status to "disabled".
  Invalidates cache after successful update.
  """
  @spec delete(String.t()) :: {:ok, t()} | {:error, :not_found}
  def delete(id) do
    case get(id) do
      {:ok, agent} ->
        case agent
             |> Schema.changeset(%{status: "disabled"})
             |> Repo.update() do
          {:ok, _updated_agent} = result ->
            Fleetlm.Agent.Cache.invalidate(id)
            result

          error ->
            error
        end

      {:error, :not_found} = error ->
        error
    end
  end

  @doc """
  Check if an agent is enabled.
  """
  @spec enabled?(String.t()) :: boolean()
  def enabled?(id) when is_binary(id) do
    case get(id) do
      {:ok, %{status: "enabled"}} -> true
      _ -> false
    end
  end
end
