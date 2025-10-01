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

  @num_storage_slots Application.compile_env(:fleetlm, :num_storage_slots, 64)

  ## Session Operations (Database)

  @doc """
  Create a session. Hits database immediately - not for hot-path.
  """
  @spec create_session(String.t(), String.t(), term()) :: {:ok, Session.t()} | {:error, any()}
  def create_session(user_id, agent_id, metadata) do
    session_id = Ulid.generate()
    shard_key = storage_slot_for_session(session_id)

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
  Get all sessions this participant is involved in (either as user or agent).
  """
  @spec get_sessions_for_participant(String.t()) :: {:ok, [Session.t()]}
  def get_sessions_for_participant(participant_id) do
    sessions =
      Session
      |> where(
        [s],
        (s.user_id == ^participant_id or s.agent_id == ^participant_id) and
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
  Append a message to the storage layer.

  Fast operation - writes to disk_log WAL, returns immediately.
  Message is persisted to DB asynchronously by PersistenceWorker.

  Caller must provide seq number (managed upstream by session).
  """
  @spec append_message(
          String.t(),
          non_neg_integer(),
          String.t(),
          String.t(),
          String.t(),
          term(),
          term()
        ) ::
          :ok | {:error, term()}
  def append_message(session_id, seq, sender_id, recipient_id, kind, content, metadata \\ %{})
      when is_binary(session_id) and is_integer(seq) and is_binary(sender_id) and
             is_binary(recipient_id) and is_binary(kind) and not is_nil(content) do
    # NOTE: this method is on the extreme hot-path and should be optimized as much as possible.
    # It's called for every message across all sessions in a slot, so it's critical to keep it fast.
    slot = storage_slot_for_session(session_id)
    ensure_slot_server_started(slot)

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
    slot = storage_slot_for_session(session_id)
    ensure_slot_server_started(slot)

    # Get the tail of the messages from the slot log, assuming
    # they may be there.
    tail =
      case SlotLogServer.read(slot, session_id, after_seq) do
        {:ok, entries} ->
          entries
          |> Enum.filter(&(&1.seq > after_seq))
          |> Enum.sort_by(& &1.seq)
          |> Enum.map(&Entry.to_message/1)

        {:error, _} ->
          []
      end

    # If the slot server has enough messages to satisfy the limit,
    # return them directly without hitting the database.
    case length(tail) >= limit do
      true ->
        {:ok, Enum.take(tail, limit)}

      false ->
        entry_seqs = tail |> Enum.map(& &1.seq) |> MapSet.new()
        remaining = max(limit - length(tail), 0)
        # Over-fetch a bit to safely account for any overlap with slot entries
        db_limit = remaining + MapSet.size(entry_seqs)

        db_messages =
          Message
          |> where([m], m.session_id == ^session_id and m.seq > ^after_seq)
          |> order_by([m], asc: m.seq)
          |> limit(^db_limit)
          |> Repo.all()
          |> Enum.reject(fn message -> MapSet.member?(entry_seqs, message.seq) end)

        messages =
          (db_messages ++ tail)
          |> Enum.sort_by(& &1.seq)
          |> Enum.take(limit)

        {:ok, messages}
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
  Update read cursor for a participant on a session.

  Hits database - not for hot-path.
  """
  @spec update_cursor(String.t(), String.t(), non_neg_integer()) ::
          {:ok, Cursor.t()} | {:error, Ecto.Changeset.t()} | no_return
  def update_cursor(session_id, participant_id, last_seq) do
    shard_key = storage_slot_for_session(session_id)

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

  # Private helpers

  # Calculate the storage slot for a session (local per-node sharding for disk log I/O).
  # This is separate from HashRing slots which are for cluster-wide routing.
  defp storage_slot_for_session(session_id) when is_binary(session_id) do
    :erlang.phash2(session_id, @num_storage_slots)
  end

  # Ensure SlotLogServer is started for the given slot.
  # In production mode (slot_log_mode: :production), servers are pre-started by supervisor - no-op.
  # In test mode (slot_log_mode: :test), servers are started on-demand with test-specific config.
  defp ensure_slot_server_started(slot) do
    if Application.get_env(:fleetlm, :slot_log_mode, :production) == :test do
      registry = Application.get_env(:fleetlm, :slot_log_registry, :global)
      task_supervisor = Application.get_env(:fleetlm, :slot_log_task_supervisor)

      case Registry.lookup(registry, slot) do
        [{_pid, _}] ->
          :ok

        [] ->
          # Start on-demand via DynamicSupervisor
          # We need a way to supervise these. For now, start unsupervised in test mode.
          # Tests are responsible for cleanup via on_exit.
          case SlotLogServer.start_link({slot, task_supervisor: task_supervisor, registry: registry}) do
            {:ok, _pid} -> :ok
            {:error, {:already_started, _pid}} -> :ok
            {:error, reason} -> {:error, reason}
          end
      end
    else
      :ok
    end
  end
end
