defmodule Fleetlm.Agents do
  @moduledoc """
  Context for managing agent participants and webhook endpoints.
  """

  import Ecto.Query

  alias Fleetlm.Repo
  alias Fleetlm.Participants
  alias Fleetlm.Participants.Participant
  alias Fleetlm.Agents.{AgentEndpoint, DeliveryLog}
  alias Ulid

  @doc """
  Register or update an agent participant and its endpoint in a single call.
  """
  @spec upsert_agent(map()) ::
          {:ok, %{participant: Participant.t(), endpoint: AgentEndpoint.t() | nil}}
          | {:error, Ecto.Changeset.t()}
  def upsert_agent(attrs) do
    Repo.transaction(fn ->
      {:ok, participant} =
        Participants.upsert_participant(%{
          id: attrs[:id] || attrs["id"],
          kind: "agent",
          display_name:
            attrs[:display_name] || attrs["display_name"] || attrs[:id] || attrs["id"],
          metadata: attrs[:metadata] || attrs["metadata"] || %{}
        })

      endpoint_attrs = attrs[:endpoint] || attrs["endpoint"]

      endpoint =
        case endpoint_attrs do
          nil -> nil
          map when is_map(map) -> upsert_endpoint!(participant.id, map)
        end

      %{participant: participant, endpoint: endpoint}
    end)
  end

  @doc """
  Upsert an agent endpoint.
  """
  @spec upsert_endpoint!(String.t(), map()) :: AgentEndpoint.t()
  def upsert_endpoint!(agent_id, attrs) do
    attrs =
      attrs
      |> Map.put(:agent_id, agent_id)
      |> Map.put_new(:id, Ulid.generate())

    Repo.get_by(AgentEndpoint, agent_id: agent_id)
    |> case do
      nil -> %AgentEndpoint{}
      endpoint -> endpoint
    end
    |> AgentEndpoint.changeset(attrs)
    |> Repo.insert_or_update!()
  end

  @doc """
  Fetch endpoint by agent id.
  """
  @spec get_endpoint(String.t()) :: AgentEndpoint.t() | nil
  def get_endpoint(agent_id) when is_binary(agent_id) do
    Repo.get_by(AgentEndpoint, agent_id: agent_id)
  end

  @doc """
  Persist a delivery log entry for webhook attempts.
  """
  @spec log_delivery(map()) :: {:ok, DeliveryLog.t()} | {:error, Ecto.Changeset.t()}
  def log_delivery(attrs) do
    %DeliveryLog{}
    |> DeliveryLog.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  List delivery logs for an agent (optional limit).
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

  @doc """
  List agents with optional status filtering.
  """
  @spec list_agents(keyword()) :: [Participant.t()]
  def list_agents(opts \\ []) do
    Participants.list_participants(Keyword.put(opts, :kind, "agent"))
  end
end
