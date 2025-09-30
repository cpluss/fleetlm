defmodule FleetLM.Storage.API do
  @moduledoc """
  Public API for the storage layer.

  Provides high-level operations for:
  - Session management (DB operations)
  - Message append (hot-path: disk_log WAL)
  - Message retrieval (disk_log + DB fallback)
  - Read cursor tracking
  """

  import Ecto.Query
  require Logger

  alias FleetLM.Storage.Model.{Session, Message, Cursor}
  alias FleetLM.Storage.{SlotLogServer, Entry}
  alias Fleetlm.Repo

  @num_slots Application.compile_env(:fleetlm, :num_storage_slots, 64)

  ## Session Operations (Database)

  @doc """
  Create a session. Hits database immediately - not for hot-path.
  """
  @spec create_session(String.t(), String.t(), map()) :: {:ok, Session.t()} | {:error, any()}
  def create_session(sender_id, recipient_id, metadata) do
    session_id = Ulid.generate()
    shard_key = slot_for_session(session_id)

    %Session{id: session_id}
    |> Session.changeset(%{
      sender_id: sender_id,
      recipient_id: recipient_id,
      metadata: metadata,
      shard_key: shard_key
    })
    |> Repo.insert()
  end

  @doc """
  Get sessions for a sender.
  """
  @spec get_sessions_for_sender(String.t()) :: {:ok, [Session.t()]}
  def get_sessions_for_sender(sender_id) do
    sessions =
      Session
      |> where([s], s.sender_id == ^sender_id)
      |> Repo.all()

    {:ok, sessions}
  end

  @doc """
  Archive a session. Sets status to 'archived'.
  """
  @spec archive_session(String.t()) :: {:ok, Session.t()} | {:error, :not_found | Ecto.Changeset.t()} | no_return
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

  ## Message Operations (Hot-Path: Disk Log)

  @doc """
  Append a message to the storage layer.

  Fast operation - writes to disk_log WAL, returns immediately.
  Message is persisted to DB asynchronously by PersistenceWorker.

  Caller must provide seq number (managed upstream by session).
  """
  @spec append_message(String.t(), non_neg_integer(), String.t(), String.t(), String.t(), map(), map()) ::
          :ok | {:error, term()}
  def append_message(session_id, seq, sender_id, recipient_id, kind, content, metadata \\ %{}) do
    slot = slot_for_session(session_id)

    # Create message struct (will be persisted to DB later)
    message = %Message{
      id: Ulid.generate(),
      session_id: session_id,
      sender_id: sender_id,
      recipient_id: recipient_id,
      seq: seq,
      kind: kind,
      content: content,
      metadata: metadata,
      shard_key: slot,
      inserted_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    }

    entry = Entry.from_message(slot, seq, Ulid.generate(), message)
    SlotLogServer.append(slot, entry)
  end

  @doc """
  Get messages for a session, starting after a sequence number.

  Checks disk_log first (recent messages), falls back to DB for older messages.
  """
  @spec get_messages(String.t(), non_neg_integer(), pos_integer()) ::
          {:ok, [Message.t()]}
  def get_messages(session_id, after_seq, limit) do
    # For now, just query DB
    # TODO: Check disk_log first, then fall back to DB
    messages =
      Message
      |> where([m], m.session_id == ^session_id and m.seq > ^after_seq)
      |> order_by([m], asc: m.seq)
      |> limit(^limit)
      |> Repo.all()

    {:ok, messages}
  end

  ## Cursor Operations (Database)

  @doc """
  Update read cursor for a participant on a session.

  Hits database - not for hot-path.
  """
  @spec update_cursor(String.t(), String.t(), non_neg_integer()) ::
          {:ok, Cursor.t()} | {:error, Ecto.Changeset.t()} | no_return
  def update_cursor(session_id, participant_id, last_seq) do
    shard_key = slot_for_session(session_id)

    attrs = %{
      session_id: session_id,
      participant_id: participant_id,
      last_seq: last_seq,
      shard_key: shard_key
    }

    %Cursor{}
    |> Cursor.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:last_seq, :updated_at]},
      conflict_target: [:session_id, :participant_id]
    )
  end

  ## Private Helpers

  defp slot_for_session(session_id) when is_binary(session_id) do
    :erlang.phash2(session_id, @num_slots)
  end
end
