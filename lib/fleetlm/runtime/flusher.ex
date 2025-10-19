defmodule Fleetlm.Runtime.Flusher do
  @moduledoc """
  Background process that flushes Raft state to Postgres for durability.

  ## Write-Behind Strategy

  1. Messages appended to Raft (RAM, 3× replicated) → ACK immediately
  2. Flusher runs every 5s (tunable)
  3. Query unflushed messages from all 256 Raft groups (local query, cheap)
  4. Batch insert to Postgres (idempotent, on_conflict: :nothing)
  5. Advance watermark per lane (triggers Raft log compaction)
  6. Raft deletes entries ≤ watermark from ETS ring

  ## Durability Guarantee

  - Raft quorum (2/3 replicas) = durable in RAM
  - Postgres flush = additional durability layer
  - If entire cluster crashes: lose up to 5s of messages (acceptable for chat)
  - If single node crashes: zero data loss (other replicas have the data)

  ## Performance

  - Flush interval: 5s (tunable via config)
  - Parallel flushes across all 256 groups
  - Idempotent inserts (safe to retry)
  - Only leader can advance watermark (followers ignore command failures)
  """

  use GenServer
  require Logger

  alias Fleetlm.Storage.Model.Message
  alias Fleetlm.Runtime.{RaftManager, RaftFSM}
  alias Fleetlm.Repo

  @flush_interval Application.compile_env(:fleetlm, :raft_flush_interval_ms, 5000)

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    Logger.info("Flusher started, interval: #{@flush_interval}ms")
    schedule_flush()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:flush, state) do
    start_time = System.monotonic_time(:millisecond)

    # Flush all groups in parallel
    # TODO: don't hardcode 256 groups
    tasks =
      for group_id <- 0..255 do
        Task.async(fn -> flush_group(group_id) end)
      end

    # Wait for all flushes (with timeout)
    results = Task.await_many(tasks, :timer.seconds(10))

    # Count successes and failures
    {total_messages, failed_groups} =
      Enum.reduce(results, {0, 0}, fn
        {:ok, count}, {total, fails} -> {total + count, fails}
        {:error, _}, {total, fails} -> {total, fails + 1}
        :skip, acc -> acc
      end)

    elapsed = System.monotonic_time(:millisecond) - start_time

    if total_messages > 0 or failed_groups > 0 do
      Logger.info(
        "Flusher: Flushed #{total_messages} messages across #{256 - failed_groups} groups in #{elapsed}ms (#{failed_groups} failures)"
      )
    end

    schedule_flush()
    {:noreply, state}
  end

  # Private helpers

  defp schedule_flush do
    interval = Application.get_env(:fleetlm, :raft_flush_interval_ms, @flush_interval)
    Process.send_after(self(), :flush, interval)
  end

  defp flush_group(group_id) do
    start_time = System.monotonic_time(:microsecond)
    server_id = RaftManager.server_id(group_id)

    # Try to query - if Ra server doesn't exist, local_query will fail gracefully
    case :ra.local_query({server_id, Node.self()}, &RaftFSM.query_unflushed/1) do
      # local_query returns: {:ok, {RaftIndex, QueryResult}, LeaderStatus}
      {:ok, {_index_term, unflushed_by_lane}, _leader_status} when map_size(unflushed_by_lane) > 0 ->
        flush_unflushed_messages(group_id, server_id, unflushed_by_lane, start_time)

      {:ok, {_index_term, _empty_map}, _leader_status} ->
        # No unflushed messages
        :skip

      {:timeout, _} ->
        # Group exists but query timed out
        Logger.error("Flush query timeout for group #{group_id}")
        :skip

      {:error, :unknown_raft_server} ->
        # Group not started (common in test mode)
        Logger.warning("Group #{group_id} not started, can not flush")
        :skip

      {:error, reason} ->
        duration_us = System.monotonic_time(:microsecond) - start_time
        Fleetlm.Observability.Telemetry.emit_raft_flush(:error, group_id, 0, duration_us)
        Logger.error("Failed to query unflushed for group #{group_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp flush_unflushed_messages(group_id, server_id, unflushed_by_lane, start_time) do
    # Flatten all lanes' messages
    all_messages =
      unflushed_by_lane
      |> Map.values()
      |> List.flatten()
      |> Enum.map(&to_message_map(&1, group_id))

    # Batch insert to Postgres (idempotent!)
    # NOTE: Chunked to avoid Postgres 65535 parameter limit
    # With 10 fields per message, we can safely insert ~6500 messages
    # Use 5000 for safety margin (same as old SlotLogServer)
    # TODO: make this configurable, not hardcoded
    {inserted_count, _} =
      all_messages
      |> Enum.chunk_every(5000)
      |> Enum.reduce({0, nil}, fn chunk, {acc_count, _} ->
        {count, _} =
          Repo.insert_all(
            Message,
            chunk,
            on_conflict: :nothing,
            conflict_target: [:session_id, :seq]
          )

        {acc_count + count, nil}
      end)

    # Emit flush telemetry
    # TODO: add telemetry for number of chunks and messages per chunk
    duration_us = System.monotonic_time(:microsecond) - start_time
    Fleetlm.Observability.Telemetry.emit_raft_flush(:ok, group_id, inserted_count, duration_us)

    # Advance watermark per lane (only leader processes commands)
    for {lane, messages} <- unflushed_by_lane do
      max_seq = Enum.max_by(messages, & &1.seq).seq

      case :ra.process_command(
             {server_id, Node.self()},
             {:advance_watermark, lane, max_seq},
             # TODO: check if this can be real value vs. the max limit
             # per chunk.
             5000
           ) do
        {:ok, :ok, _} ->
          :ok

        {:timeout, _} ->
          Logger.warning(
            "Watermark advance timeout for group #{group_id} lane #{lane} seq #{max_seq}"
          )

        {:error, :not_leader} ->
          # Expected on followers, ignore
          :ok

        {:error, reason} ->
          Logger.error(
            "Failed to advance watermark for group #{group_id} lane #{lane}: #{inspect(reason)}"
          )
      end
    end

    {:ok, inserted_count}
  end

  defp to_message_map(message, group_id) do
    %{
      id: message.id,
      session_id: message.session_id,
      sender_id: message.sender_id,
      recipient_id: message.recipient_id,
      seq: message.seq,
      kind: message.kind,
      content: message.content,
      metadata: message.metadata,
      shard_key: group_id,
      inserted_at: message.inserted_at
    }
  end
end
