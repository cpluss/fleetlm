defmodule Fleetlm.Context.SnapshotStore do
  @moduledoc """
  Persists context snapshots to Postgres so we can reload them on cold start
  without replaying the full message history.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias Fleetlm.Repo

  @primary_key {:session_id, :string, []}
  schema "context_snapshots" do
    field :strategy_id, :string
    field :strategy_version, :string
    field :snapshot, :binary
    field :token_count, :integer
    field :last_compacted_seq, :integer
    field :last_included_seq, :integer
    field :updated_at, :utc_datetime_usec
  end

  @spec persist(String.t(), Fleetlm.Context.Snapshot.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def persist(session_id, snapshot) do
    encoded = :erlang.term_to_binary(snapshot)

    changeset =
      %__MODULE__{session_id: session_id}
      |> cast(
        %{
          strategy_id: snapshot.strategy_id,
          strategy_version: snapshot.strategy_version,
          snapshot: encoded,
          token_count: snapshot.token_count,
          last_compacted_seq: snapshot.last_compacted_seq || 0,
          last_included_seq: snapshot.last_included_seq || 0,
          updated_at: DateTime.utc_now()
        },
        [
          :strategy_id,
          :strategy_version,
          :snapshot,
          :token_count,
          :last_compacted_seq,
          :last_included_seq,
          :updated_at
        ]
      )
      |> validate_required([:strategy_id, :snapshot, :token_count])

    Repo.insert(changeset,
      on_conflict: {:replace_all_except, [:session_id]},
      conflict_target: :session_id
    )
    |> case do
      {:ok, _} -> {:ok, byte_size(encoded)}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @spec load(String.t()) :: {:ok, Fleetlm.Context.Snapshot.t()} | {:error, :not_found | term()}
  def load(session_id) do
    case Repo.get(__MODULE__, session_id) do
      nil ->
        {:error, :not_found}

      record ->
        try do
          {:ok, :erlang.binary_to_term(record.snapshot)}
        rescue
          error -> {:error, error}
        end
    end
  end

  @spec delete(String.t()) :: :ok
  def delete(session_id) do
    Repo.delete_all(from s in __MODULE__, where: s.session_id == ^session_id)
    :ok
  end
end
