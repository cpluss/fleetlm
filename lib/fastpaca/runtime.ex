defmodule Fastpaca.Runtime do
  @moduledoc """
  High-level API for the Raft-based context runtime.

  This is the ONLY interface controllers should use.
  No other modules should call :ra directly.

  ## Architecture

  - 256 Raft groups × 3 replicas
  - Each group: 16 lanes for parallel writes
  - Context metadata cached in Raft state (NO DB queries on hot path)
  """

  require Logger

  alias Fastpaca.Runtime.{RaftManager, RaftFSM}
  alias Fastpaca.Storage.Model.{Context, Message}
  alias Fastpaca.Repo

  @raft_timeout Application.compile_env(:fastpaca, :raft_command_timeout_ms, 2000)

  @doc """
  Append a message to a context.

  ## Flow

  1. Determine Raft group + lane from context_id
  2. Call :ra.process_command with {:append_batch, lane, frames}
  3. Raft commits to quorum (RAM, 3× replicated)
  4. Check trigger, maybe compact
  5. Return {:ok, seq, version, token_estimate}
  """
  @spec append_message(String.t(), map(), map()) ::
          {:ok, non_neg_integer(), non_neg_integer(), non_neg_integer()}
          | {:timeout, term()}
          | {:error, term()}
  def append_message(context_id, message, opts \\ %{})
      when is_binary(context_id) and is_map(message) do
    start_time = System.monotonic_time(:microsecond)

    # Extract message fields
    role = message[:role] || message["role"]
    parts = message[:parts] || message["parts"]
    metadata = message[:metadata] || message["metadata"] || %{}

    # Validate
    unless role in ["user", "assistant", "system", "tool"] do
      raise ArgumentError, "invalid role: #{inspect(role)}"
    end

    unless is_list(parts) and length(parts) > 0 do
      raise ArgumentError, "parts must be a non-empty list"
    end

    # Determine Raft group and lane
    group_id = RaftManager.group_for_context(context_id)
    lane = RaftManager.lane_for_context(context_id)
    server_id = RaftManager.server_id(group_id)

    # Ensure Raft group is started
    case ensure_group_started(group_id) do
      :ok ->
        # Build frame
        frames = [{context_id, role, parts, metadata}]

        # Call Raft
        result =
          :ra.process_command(
            {server_id, Node.self()},
            {:append_batch, lane, frames},
            @raft_timeout
          )

        duration_us = System.monotonic_time(:microsecond) - start_time
        handle_append_result(result, context_id, duration_us)

      {:error, reason} ->
        duration_us = System.monotonic_time(:microsecond) - start_time
        Logger.error("Failed to start group for append: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Get the pre-computed context window (for LLM).

  Pure read - no compaction logic here!
  """
  @spec get_context_window(String.t()) ::
          {:ok, %{messages: [map()], version: non_neg_integer(), used_tokens: non_neg_integer(), needs_compaction: boolean()}}
          | {:error, term()}
  def get_context_window(context_id) when is_binary(context_id) do
    group_id = RaftManager.group_for_context(context_id)
    lane = RaftManager.lane_for_context(context_id)
    server_id = RaftManager.server_id(group_id)

    # Get context from Raft state (fast, in RAM)
    case :ra.local_query({server_id, Node.self()}, fn state ->
           RaftFSM.query_contexts(state, lane)
         end) do
      {:ok, {_index_term, contexts}, _leader_status} ->
        case Map.get(contexts, context_id) do
          nil ->
            {:error, :context_not_found}

          context ->
            snapshot = context.snapshot || %{summary_messages: [], pending_messages: [], token_count: 0, metadata: %{}}
            messages = (snapshot.summary_messages || []) ++ (snapshot.pending_messages || [])

            {:ok,
             %{
               messages: messages,
               version: context.version,
               used_tokens: snapshot.token_count,
               needs_compaction: Map.get(snapshot.metadata, :needs_compaction, false)
             }}
        end

      {:timeout, _leader} ->
        {:error, :timeout}

      _other ->
        {:error, :unavailable}
    end
  end

  @doc """
  Get messages from a context (for replay/list).
  """
  @spec get_messages(String.t(), non_neg_integer(), pos_integer()) ::
          {:ok, [map()]}
  def get_messages(context_id, after_seq, limit)
      when is_binary(context_id) and is_integer(after_seq) and is_integer(limit) and limit > 0 do
    group_id = RaftManager.group_for_context(context_id)
    lane = RaftManager.lane_for_context(context_id)
    server_id = RaftManager.server_id(group_id)

    # Get from Raft (in-memory tail)
    tail =
      case :ra.leader_query({server_id, Node.self()}, fn state ->
             RaftFSM.query_messages(state, lane, context_id, after_seq)
           end) do
        {:ok, {_index_term, messages}, _leader_status} ->
          messages

        {:timeout, _leader} ->
          []

        _ ->
          []
      end

    # For now, just return tail (Postgres flusher disabled)
    # In v1.1, we'll fall back to Postgres for older messages
    {:ok, Enum.take(tail, limit)}
  end

  @doc """
  Manual compaction - replace a range of messages with summary.
  """
  @spec compact(String.t(), non_neg_integer(), non_neg_integer(), [map()]) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def compact(context_id, from_seq, to_seq, replacement_messages)
      when is_binary(context_id) and is_integer(from_seq) and is_integer(to_seq) and
             is_list(replacement_messages) do
    group_id = RaftManager.group_for_context(context_id)
    lane = RaftManager.lane_for_context(context_id)
    server_id = RaftManager.server_id(group_id)

    case :ra.process_command(
           {server_id, Node.self()},
           {:compact, lane, context_id, from_seq, to_seq, replacement_messages},
           @raft_timeout
         ) do
      {:ok, {:reply, {:ok, new_version}}, _leader} ->
        {:ok, new_version}

      {:ok, {:reply, {:error, reason}}, _leader} ->
        {:error, reason}

      {:timeout, leader} ->
        Logger.warning("Raft compact timeout for context #{context_id}, leader: #{inspect(leader)}")
        {:error, :timeout}

      {:error, reason} ->
        Logger.error("Raft compact error for context #{context_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Private helpers

  defp handle_append_result(result, context_id, duration_us) do
    case result do
      {:ok, {:reply, {:ok, [{^context_id, seq, message_id}]}}, _leader} ->
        # Success - message appended
        # Note: Compaction and broadcasts already happened in FSM
        # Token estimate (rough: 4 chars per token)
        token_estimate = 10  # Placeholder

        {:ok, seq, seq, token_estimate}

      {:timeout, leader} ->
        Logger.warning("Raft append timeout for context #{context_id}, leader: #{inspect(leader)}")
        {:timeout, leader}

      {:error, reason} ->
        Logger.error("Raft append error for context #{context_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp ensure_group_started(group_id) do
    case RaftManager.start_group(group_id) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to start Raft group #{group_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
