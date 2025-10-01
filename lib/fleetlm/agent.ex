defmodule Fleetlm.Agent do
  @moduledoc """
  Agent context for managing external AI agent endpoints.

  Agents are stateless HTTP endpoints that receive message history
  and return responses synchronously.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Fleetlm.Repo
  alias Fleetlm.Agent.DeliveryLog

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :string

  @type t :: %__MODULE__{}

  schema "agents" do
    field :name, :string
    field :origin_url, :string
    field :webhook_path, :string, default: "/webhook"

    # Message history configuration
    field :message_history_mode, :string, default: "tail"
    field :message_history_limit, :integer, default: 50

    # HTTP configuration
    field :timeout_ms, :integer, default: 30_000
    field :headers, :map, default: %{}
    field :status, :string, default: "enabled"

    timestamps()
  end

  @doc """
  Changeset for creating/updating agents.
  """
  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [
      :id,
      :name,
      :origin_url,
      :webhook_path,
      :message_history_mode,
      :message_history_limit,
      :timeout_ms,
      :headers,
      :status
    ])
    |> validate_required([:id, :name, :origin_url, :webhook_path])
    |> validate_inclusion(:message_history_mode, ["tail", "entire", "last"])
    |> validate_inclusion(:status, ["enabled", "disabled"])
    |> validate_number(:timeout_ms, greater_than: 0)
    |> validate_number(:message_history_limit, greater_than: 0)
    |> unique_constraint(:id, name: :agents_pkey)
  end

  ## Public API

  @doc """
  Create a new agent.
  """
  @spec create(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Get an agent by ID.
  """
  @spec get(String.t()) :: {:ok, t()} | {:error, :not_found}
  def get(id) when is_binary(id) do
    case Repo.get(__MODULE__, id) do
      nil -> {:error, :not_found}
      agent -> {:ok, agent}
    end
  end

  @doc """
  Get agent without error tuple (raises if not found).
  """
  @spec get!(String.t()) :: t()
  def get!(id) when is_binary(id) do
    Repo.get!(__MODULE__, id)
  end

  @doc """
  List all agents with optional filters.

  ## Options
  - `:status` - Filter by status ("enabled" | "disabled")
  """
  @spec list(keyword()) :: [t()]
  def list(opts \\ []) do
    query = from(a in __MODULE__, order_by: [asc: a.name])

    query =
      case Keyword.get(opts, :status) do
        nil -> query
        status -> where(query, [a], a.status == ^status)
      end

    Repo.all(query)
  end

  @doc """
  Update an agent.
  """
  @spec update(String.t(), map()) :: {:ok, t()} | {:error, Ecto.Changeset.t() | :not_found}
  def update(id, attrs) do
    case get(id) do
      {:ok, agent} ->
        agent
        |> changeset(attrs)
        |> Repo.update()

      {:error, :not_found} = error ->
        error
    end
  end

  @doc """
  Delete (disable) an agent.
  Soft delete by setting status to "disabled".
  """
  @spec delete(String.t()) :: {:ok, t()} | {:error, :not_found}
  def delete(id) do
    case get(id) do
      {:ok, agent} ->
        agent
        |> changeset(%{status: "disabled"})
        |> Repo.update()

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

  ## Delivery Logs

  @doc """
  Log a webhook delivery attempt.
  """
  @spec log_delivery(map()) :: {:ok, DeliveryLog.t()} | {:error, Ecto.Changeset.t()}
  def log_delivery(attrs) do
    %DeliveryLog{}
    |> DeliveryLog.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  List delivery logs for an agent.
  """
  @spec list_delivery_logs(String.t(), keyword()) :: [DeliveryLog.t()]
  def list_delivery_logs(agent_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    DeliveryLog
    |> where(agent_id: ^agent_id)
    |> order_by([d], desc: d.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end
end
