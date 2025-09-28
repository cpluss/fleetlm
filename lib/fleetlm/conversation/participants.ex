defmodule Fleetlm.Conversation.Participants do
  @moduledoc """
  Context helpers for Participant CRUD used by the chat runtime and REST API.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Fleetlm.Repo
  alias Fleetlm.Conversation.Participant

  @typedoc "Identifier of a participant (user, agent, or system)."
  @type participant_id :: String.t()

  @typedoc "Attributes allowed when registering or updating a participant."
  @type participant_attrs :: %{
          required(:id) => participant_id(),
          required(:kind) => String.t(),
          required(:display_name) => String.t(),
          optional(:status) => String.t(),
          optional(:metadata) => map()
        }

  @doc """
  Create a participant. Raises if required keys are missing.
  """
  @spec create_participant(participant_attrs()) ::
          {:ok, Participant.t()} | {:error, Changeset.t()}
  def create_participant(%{id: _id, kind: _kind, display_name: _name} = attrs) do
    attrs
    |> ensure_defaults()
    |> do_create()
  end

  @doc """
  Idempotent helper used across the codebase. Creates or updates a participant
  depending on whether the id already exists.
  """
  @spec upsert_participant(participant_attrs()) ::
          {:ok, Participant.t()} | {:error, Changeset.t()}
  def upsert_participant(%{id: id} = attrs) do
    attrs = ensure_defaults(attrs)

    case Repo.get(Participant, id) do
      nil ->
        do_create(attrs)

      %Participant{} = participant ->
        participant
        |> Participant.changeset(attrs)
        |> Repo.update()
    end
  end

  @doc """
  Update the stored participant.
  """
  @spec update_participant(participant_id(), map()) ::
          {:ok, Participant.t()} | {:error, Changeset.t()} | {:error, :not_found}
  def update_participant(id, attrs) when is_binary(id) and is_map(attrs) do
    with {:ok, participant} <- get_participant(id) do
      participant
      |> Participant.changeset(attrs)
      |> Repo.update()
    end
  end

  @doc """
  Delete a participant by id.
  """
  @spec delete_participant(participant_id()) ::
          {:ok, Participant.t()} | {:error, :not_found}
  def delete_participant(id) when is_binary(id) do
    with {:ok, participant} <- get_participant(id) do
      Repo.delete(participant)
    end
  end

  @doc """
  Fetch a participant by id, returning an error tuple if missing.
  """
  @spec get_participant(participant_id()) :: {:ok, Participant.t()} | {:error, :not_found}
  def get_participant(id) when is_binary(id) do
    case Repo.get(Participant, id) do
      nil -> {:error, :not_found}
      participant -> {:ok, participant}
    end
  end

  @doc """
  Fetch a participant and raise if it cannot be found.
  """
  @spec get_participant!(participant_id()) :: Participant.t()
  def get_participant!(id) when is_binary(id) do
    Repo.get!(Participant, id)
  end

  @doc """
  List participants filtered by optional kind/status filters.
  """
  @spec list_participants(keyword()) :: [Participant.t()]
  def list_participants(opts \\ []) do
    query = from(p in Participant)

    query =
      case Keyword.get(opts, :kind) do
        nil -> query
        kind -> from p in query, where: p.kind == ^kind
      end

    query =
      case Keyword.get(opts, :status) do
        nil -> query
        status -> from p in query, where: p.status == ^status
      end

    Repo.all(query)
  end

  defp do_create(attrs) do
    %Participant{}
    |> Participant.changeset(attrs)
    |> Repo.insert()
  end

  defp ensure_defaults(attrs) do
    attrs
    |> Map.put_new(:status, "active")
    |> Map.update(:metadata, %{}, fn
      nil -> %{}
      value when is_map(value) -> value
      value -> value
    end)
  end
end
