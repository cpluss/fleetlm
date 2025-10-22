defmodule Fleetlm.Runtime do
  @moduledoc """
  High-level API for the Raft-based message runtime.

  This is the ONLY interface the rest of the application should use.
  No other modules should call :ra directly - they should go through this API.

  ## Architecture

  - 256 Raft groups × 3 replicas
  - Each group: 16 lanes for parallel writes
  - Conversation metadata cached in Raft state (NO DB queries on hot path!)
  - Background flush to Postgres every 5s

  ## Usage

  ```elixir
  # Append a message (fast path: Raft RAM → ACK in 2-5ms)
  {:ok, seq} = Runtime.append_message(session_id, sender_id, kind, content, metadata)

  # Get messages (hybrid: Raft tail + Postgres fallback)
  {:ok, messages} = Runtime.get_messages(session_id, after_seq, limit)
  ```
  """

  require Logger

  alias Fleetlm.Runtime.{RaftManager, RaftFSM}
  alias Fleetlm.Storage.Model.Message
  alias Fleetlm.Repo

  @raft_timeout Application.compile_env(:fleetlm, :raft_command_timeout_ms, 2000)

  @doc """
  Append a message to a session.

  ## Flow

  1. Determine Raft group + lane from session_id
  2. Call :ra.process_command with {:append_batch, lane, frames}
  3. Raft commits to quorum (RAM, 3× replicated)
  4. Return {:ok, seq} immediately
  5. Background Flusher writes to Postgres every 5s

  ## Returns

  - `{:ok, seq}` - Message committed to Raft quorum
  - `{:timeout, leader}` - Raft command timed out
  - `{:error, reason}` - Raft command failed
  """
  @spec append_message(String.t(), String.t(), String.t(), String.t(), map(), map()) ::
          {:ok, non_neg_integer()} | {:timeout, term()} | {:error, term()}
  def append_message(session_id, sender_id, recipient_id, kind, content, metadata \\ %{})
      when is_binary(session_id) and is_binary(sender_id) and is_binary(recipient_id) and
             is_binary(kind) and is_map(content) and is_map(metadata) do
    # Emit telemetry for append attempt
    start_time = System.monotonic_time(:microsecond)

    # Determine Raft group and lane
    group_id = RaftManager.group_for_session(session_id)
    lane = RaftManager.lane_for_session(session_id)
    server_id = RaftManager.server_id(group_id)

    # Ensure Raft group is started (lazy initialization in test mode)
    case ensure_group_started(group_id) do
      :ok ->
        # Build frame
        frames = [{session_id, sender_id, recipient_id, kind, content, metadata}]

        # Call Raft
        result =
          :ra.process_command(
            {server_id, Node.self()},
            {:append_batch, lane, frames},
            @raft_timeout
          )

        # Emit telemetry
        duration_us = System.monotonic_time(:microsecond) - start_time

        handle_append_result(
          result,
          session_id,
          sender_id,
          kind,
          content,
          metadata,
          group_id,
          lane,
          duration_us
        )

      {:error, reason} ->
        duration_us = System.monotonic_time(:microsecond) - start_time
        Fleetlm.Observability.Telemetry.emit_raft_append(:error, group_id, lane, duration_us)
        Logger.error("Failed to start group for append: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp handle_append_result(
         result,
         session_id,
         sender_id,
         kind,
         content,
         metadata,
         group_id,
         lane,
         duration_us
       ) do
    case result do
      # Ra wraps our FSM reply: {:ok, fsm_reply, leader}
      # FSM returns [{session_id, seq, message_id}]
      {:ok, {:reply, {:ok, [{^session_id, seq, message_id}]}}, _leader} ->
        Fleetlm.Observability.Telemetry.emit_raft_append(:ok, group_id, lane, duration_us)

        # Broadcast to session PubSub (for active session participants)
        # CRITICAL: Use message_id from FSM (not a new UUID!)
        message = %{
          "id" => message_id,
          "session_id" => session_id,
          "seq" => seq,
          "sender_id" => sender_id,
          "kind" => kind,
          "content" => content,
          "metadata" => metadata,
          "inserted_at" => NaiveDateTime.to_iso8601(NaiveDateTime.utc_now())
        }

        Phoenix.PubSub.broadcast(
          Fleetlm.PubSub,
          "session:#{session_id}",
          {:session_message, message}
        )

        # Broadcast notification to user's inbox AND dispatch to agent
        # Get user_id and agent_id from Raft conversation metadata
        case get_conversation_metadata(session_id) do
          %{user_id: user_id, agent_id: agent_id} when is_binary(user_id) ->
            # Inbox notification
            notification = %{
              "session_id" => session_id,
              "user_id" => user_id,
              "agent_id" => agent_id,
              "message_sender" => sender_id,
              "timestamp" => message["inserted_at"]
            }

            Phoenix.PubSub.broadcast(
              Fleetlm.PubSub,
              "user:#{user_id}:inbox",
              {:message_notification, notification}
            )

          # Agent dispatch is now handled by RaftFSM effects (no longer called from here)

          _other ->
            # Conversation metadata not cached yet (shouldn't happen after append)
            :ok
        end

        {:ok, seq}

      {:timeout, leader} ->
        Fleetlm.Observability.Telemetry.emit_raft_append(:timeout, group_id, lane, duration_us)

        Logger.warning(
          "Raft append timeout for session #{session_id}, leader: #{inspect(leader)}"
        )

        {:timeout, leader}

      {:error, reason} ->
        Fleetlm.Observability.Telemetry.emit_raft_append(:error, group_id, lane, duration_us)
        Logger.error("Raft append error for session #{session_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Get messages for a session (hybrid: Raft tail + Postgres fallback).

  ## Flow

  1. Query Raft local state for message tail (last ~5000 messages in RAM)
  2. If tail has enough messages, return immediately (fast path!)
  3. Otherwise, query Postgres for older messages (cold path)
  4. Merge and return

  ## Performance

  - Hot path (Raft tail): ~1-5ms (local ETS query)
  - Cold path (Postgres): ~10-50ms (DB query)

  ## Returns

  - `{:ok, [message]}` - List of messages (sorted by seq)
  """
  @spec get_messages(String.t(), non_neg_integer(), pos_integer()) ::
          {:ok, [map()]}
  def get_messages(session_id, after_seq, limit)
      when is_binary(session_id) and is_integer(after_seq) and is_integer(limit) and limit > 0 do
    start_time = System.monotonic_time(:microsecond)

    # Determine Raft group and lane
    group_id = RaftManager.group_for_session(session_id)
    lane = RaftManager.lane_for_session(session_id)
    server_id = RaftManager.server_id(group_id)

    # Pick a replica node to query (preferring local if we have it)
    replica_nodes = RaftManager.replicas_for_group(group_id)
    query_node = if Node.self() in replica_nodes, do: Node.self(), else: hd(replica_nodes)

    # Get tail from Raft (hot, in RAM)
    # Use leader_query for strong consistency (ensures follower lag doesn't cause stale reads)
    tail =
      case :ra.leader_query({server_id, query_node}, fn state ->
             RaftFSM.query_messages(state, lane, session_id, after_seq)
           end) do
        {:ok, {_index_term, messages}, _leader_status} ->
          messages

        {:timeout, _leader} ->
          []

        _ ->
          []
      end

    # If tail has enough, return early (fast path!)
    if length(tail) >= limit do
      duration_us = System.monotonic_time(:microsecond) - start_time

      Fleetlm.Observability.Telemetry.emit_raft_read(
        :tail_only,
        group_id,
        length(tail),
        duration_us
      )

      {:ok, Enum.take(tail, limit)}
    else
      # Fallback to Postgres for older messages (cold path)
      tail_seqs = MapSet.new(tail, & &1.seq)
      remaining = limit - length(tail)

      import Ecto.Query

      db_messages =
        Repo.all(
          from(m in Message,
            where: m.session_id == ^session_id and m.seq > ^after_seq,
            order_by: [asc: m.seq],
            limit: ^remaining
          )
        )
        |> Enum.reject(&MapSet.member?(tail_seqs, &1.seq))

      # Merge and return
      messages =
        (db_messages ++ tail)
        |> Enum.sort_by(& &1.seq)
        |> Enum.take(limit)

      duration_us = System.monotonic_time(:microsecond) - start_time

      Fleetlm.Observability.Telemetry.emit_raft_read(
        :tail_and_db,
        group_id,
        length(messages),
        duration_us
      )

      {:ok, messages}
    end
  end

  @doc """
  Get conversation metadata from Raft state (if cached).

  Returns `nil` if session not in Raft state (cold start).
  """
  @spec get_conversation_metadata(String.t()) :: RaftFSM.Conversation.t() | nil
  def get_conversation_metadata(session_id) do
    group_id = RaftManager.group_for_session(session_id)
    lane = RaftManager.lane_for_session(session_id)
    server_id = RaftManager.server_id(group_id)

    case :ra.local_query({server_id, Node.self()}, fn state ->
           RaftFSM.query_conversations(state, lane)
         end) do
      {:ok, {_index_term, conversations}, _leader_status} ->
        Map.get(conversations, session_id)

      _other ->
        nil
    end
  end

  @doc """
  Update last_sent_seq for a session (called by agent StreamWorker).
  """
  @spec update_sent_seq(String.t(), non_neg_integer()) :: :ok | {:error, term()}
  def update_sent_seq(session_id, seq) when is_binary(session_id) and is_integer(seq) do
    group_id = RaftManager.group_for_session(session_id)
    lane = RaftManager.lane_for_session(session_id)
    server_id = RaftManager.server_id(group_id)

    case :ra.process_command(
           {server_id, Node.self()},
           {:update_sent_seq, lane, session_id, seq},
           5000
         ) do
      {:ok, :ok, _} -> :ok
      {:error, reason} -> {:error, reason}
      {:timeout, _} -> {:error, :timeout}
    end
  end

  @doc """
  Flush a session's messages to Postgres immediately (synchronous).

  Normally messages flush in the background every 5s. This forces an immediate flush.
  Used for testing and graceful shutdown.
  """
  @spec flush_session(String.t()) :: :ok | {:error, term()}
  def flush_session(_session_id) do
    # Trigger the global Flusher to flush all groups
    # (We don't have per-session flushing anymore - it's all group-based)
    send(Fleetlm.Runtime.Flusher, :flush)
    :ok
  end

  @doc """
  Report agent processing completion to the FSM.

  Called by Agent.Worker when webhook streaming finishes successfully.
  """
  @spec processing_complete(String.t(), non_neg_integer()) :: :ok | {:error, term()}
  def processing_complete(session_id, sent_seq) do
    group_id = RaftManager.group_for_session(session_id)
    lane = RaftManager.lane_for_session(session_id)
    server_id = RaftManager.server_id(group_id)

    {server_id, Node.self()}
    |> :ra.process_command({:processing_complete, lane, session_id, sent_seq}, @raft_timeout)
    |> handle_raft_result()
  end

  @doc """
  Report agent processing failure to the FSM.

  Called by Agent.Worker when webhook call fails.
  """
  @spec processing_failed(String.t(), term()) :: :ok | {:error, term()}
  def processing_failed(session_id, reason) do
    group_id = RaftManager.group_for_session(session_id)
    lane = RaftManager.lane_for_session(session_id)
    server_id = RaftManager.server_id(group_id)

    {server_id, Node.self()}
    |> :ra.process_command({:processing_failed, lane, session_id, reason}, @raft_timeout)
    |> handle_raft_result()
  end

  @doc """
  Report compaction completion to the FSM.

  Called by Compaction.Worker when summarization finishes.
  """
  @spec compaction_complete(String.t(), map()) :: :ok | {:error, term()}
  def compaction_complete(session_id, summary) do
    group_id = RaftManager.group_for_session(session_id)
    lane = RaftManager.lane_for_session(session_id)
    server_id = RaftManager.server_id(group_id)

    {server_id, Node.self()}
    |> :ra.process_command({:compaction_complete, lane, session_id, summary}, @raft_timeout)
    |> handle_raft_result()
  end

  @doc """
  Report compaction failure to the FSM.

  Called by Compaction.Worker when summarization fails.
  """
  @spec compaction_failed(String.t(), term()) :: :ok | {:error, term()}
  def compaction_failed(session_id, reason) do
    group_id = RaftManager.group_for_session(session_id)
    lane = RaftManager.lane_for_session(session_id)
    server_id = RaftManager.server_id(group_id)

    {server_id, Node.self()}
    |> :ra.process_command({:compaction_failed, lane, session_id, reason}, @raft_timeout)
    |> handle_raft_result()
  end

  # Private helpers

  defp handle_raft_result({:ok, _reply, _leader}), do: :ok
  defp handle_raft_result({:timeout, leader}), do: {:error, {:timeout, leader}}
  defp handle_raft_result({:error, reason}), do: {:error, reason}
  defp handle_raft_result(:ok), do: :ok
  defp handle_raft_result(other), do: {:error, other}

  defp ensure_group_started(group_id) do
    # RaftManager.start_group is idempotent (checks if already running)
    case RaftManager.start_group(group_id) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to start Raft group #{group_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
