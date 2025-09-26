defmodule Fleetlm.Participants do
  @moduledoc """
  Context for managing participants (users, agents, system actors).
  """

  import Ecto.Query

  alias Fleetlm.Repo
  alias Fleetlm.Participants.Participant

  @type participant_id :: String.t()

  @doc """
  Upsert a participant by id.
  """
  @spec upsert_participant(map()) :: {:ok, Participant.t()} | {:error, Ecto.Changeset.t()}
  def upsert_participant(attrs) when is_map(attrs) do
    id = Map.fetch!(attrs, :id)

    attrs =
      attrs
      |> Map.put_new(:status, "active")
      |> Map.put_new(:metadata, %{})

    Participant
    |> Repo.get(id)
    |> case do
      nil -> %Participant{id: id}
      participant -> participant
    end
    |> Participant.changeset(attrs)
    |> Repo.insert_or_update()
  end

  @doc """
  Fetch a participant by id.
  """
  @spec get_participant!(participant_id()) :: Participant.t()
  def get_participant!(id) when is_binary(id) do
    Repo.get!(Participant, id)
  end

  @doc """
  List participants filtered by kind/status.
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
end
