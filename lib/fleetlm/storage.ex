defmodule Fleetlm.Storage do
  @moduledoc """
  Storage layer for sessions and cursors.

  Provides high-level operations for:
  - Session management (DB CRUD operations)
  - Read cursor tracking

  ## Note on Architecture Change

  Message append/retrieval is now handled by `Fleetlm.Runtime` (Raft-based).
  This module only manages session metadata and read cursors.
  """

  import Ecto.Query
  require Logger

  alias Fleetlm.Storage.Model.{Session, Message, Cursor}
  alias Fleetlm.Repo

  ## Session Operations (Database)

  @doc """
  Create a session. Hits database immediately - not for hot-path.
  """
  @spec create_session(String.t(), String.t(), term()) :: {:ok, Session.t()} | {:error, any()}
  def create_session(user_id, agent_id, metadata) do
    session_id = Uniq.UUID.uuid7(:slug)
    # Use Raft group as shard_key
    shard_key = Fleetlm.Runtime.RaftManager.group_for_session(session_id)

    %Session{id: session_id}
    |> Session.changeset(%{
      user_id: user_id,
      agent_id: agent_id,
      metadata: metadata,
      shard_key: shard_key
    })
    |> Repo.insert()
  end

  @doc """
  Get sessions for a user.
  """
  @spec get_sessions_for_user(String.t()) :: {:ok, [Session.t()]}
  def get_sessions_for_user(user_id) do
    sessions =
      Session
      |> where([s], s.user_id == ^user_id and s.status != "archived")
      |> Repo.all()

    {:ok, sessions}
  end

  @doc """
  Get all sessions this identity is involved in (either as user or agent).
  """
  @spec get_sessions_for_identity(String.t()) :: {:ok, [Session.t()]}
  def get_sessions_for_identity(identity_id) do
    sessions =
      Session
      |> where(
        [s],
        (s.user_id == ^identity_id or s.agent_id == ^identity_id) and
          s.status != "archived"
      )
      |> Repo.all()

    {:ok, sessions}
  end

  @doc """
  Archive a session. Sets status to 'archived'.
  """
  @spec archive_session(String.t()) ::
          {:ok, Session.t()} | {:error, :not_found | Ecto.Changeset.t()} | no_return
  def archive_session(session_id) do
    case Repo.get(Session, session_id) do
      nil ->
        {:error, :not_found}

      session ->
        session
        |> Session.changeset(%{status: "archived"})
        |> Repo.update()
    end
  end


  @doc """
  Get a single session by ID.
  """
  @spec get_session(String.t()) :: {:ok, Session.t()} | {:error, :not_found}
  def get_session(session_id) do
    case Repo.get(Session, session_id) do
      nil -> {:error, :not_found}
      session -> {:ok, session}
    end
  end

  @doc """
  Get ALL messages for a session (expensive!).

  This fetches every message from the database. Use sparingly.
  Prefer get_messages/3 with a limit for most use cases.
  """
  @spec get_all_messages(String.t()) :: {:ok, [Message.t()]}
  def get_all_messages(session_id) do
    messages =
      Message
      |> where([m], m.session_id == ^session_id)
      |> order_by([m], asc: m.seq)
      |> Repo.all()

    {:ok, messages}
  end

  @doc """
  Update read cursor for a user on a session.

  Hits database - not for hot-path.
  """
  @spec update_cursor(String.t(), String.t(), non_neg_integer()) ::
          {:ok, Cursor.t()} | {:error, Ecto.Changeset.t()} | no_return
  def update_cursor(session_id, user_id, last_seq) do
    # Use Raft group as shard_key
    shard_key = Fleetlm.Runtime.RaftManager.group_for_session(session_id)

    attrs = %{
      session_id: session_id,
      user_id: user_id,
      last_seq: last_seq,
      shard_key: shard_key
    }

    %Cursor{}
    |> Cursor.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:last_seq, :updated_at]},
      conflict_target: [:session_id, :user_id]
    )
  end
end
