defmodule Fleetlm.Runtime.RaftFSM do
  @moduledoc """
  Ra-based finite state machine for message storage and sequencing.

  One FSM per Raft group (256 groups total across cluster).
  Each group manages 16 lanes for parallel message appends.

  ## State Structure

  State lives entirely in RAM (Raft-replicated 3×) and contains:
  - Conversation metadata (last_seq, user_id, agent_id, etc) - NO DB QUERY!
  - Message tail (last 3-5s, ~5000 messages per lane)
  - Flush watermarks (for Raft log compaction)

  ## Write Path

  1. Client sends message → :ra.process_command({:group, group}, {:append_batch, ...})
  2. Raft commits to quorum (RAM, 2-5ms)
  3. ACK to client immediately
  4. Background Flusher writes to Postgres every 5s
  5. Advance watermark → Raft log compaction
  6. Snapshot checkpoint (every 250ms or 256KB)

  ## Recovery

  On restart:
  1. Load latest snapshot from Postgres
  2. Rebuild ETS rings from snapshot
  3. Replay Raft log from snapshot index
  4. Ready to serve
  """

  @behaviour :ra_machine

  require Logger

  alias Fleetlm.Storage.Model.{Session, Message}
  alias Fleetlm.Repo

  @num_lanes 16
  @ring_capacity 5000
  @snapshot_interval_ms 250
  @snapshot_bytes_threshold 256 * 1024
  # Evict after 1 hour inactivity
  @conversation_ttl_seconds 3600

  defmodule Conversation do
    @moduledoc "Hot metadata for a session (replicated in Raft state)"

    @enforce_keys [:last_seq, :last_sent_seq, :user_id, :agent_id, :last_activity]
    defstruct [:last_seq, :last_sent_seq, :user_id, :agent_id, :last_activity]

    @type t :: %__MODULE__{
            last_seq: non_neg_integer(),
            last_sent_seq: non_neg_integer(),
            user_id: String.t(),
            agent_id: String.t() | nil,
            last_activity: NaiveDateTime.t()
          }
  end

  defmodule Lane do
    @moduledoc "One of 16 parallel message streams within a Raft group"

    @enforce_keys [:ring, :capacity, :conversations, :flush_watermark, :last_flushed_index]
    defstruct [:ring, :capacity, :conversations, :flush_watermark, :last_flushed_index]

    @type t :: %__MODULE__{
            ring: :ets.tid(),
            capacity: pos_integer(),
            conversations: %{String.t() => Conversation.t()},
            flush_watermark: non_neg_integer(),
            last_flushed_index: non_neg_integer()
          }
  end

  defstruct [:group_id, :lanes, :last_snapshot_index, :last_snapshot_time]

  @type t :: %__MODULE__{
          group_id: non_neg_integer(),
          lanes: %{non_neg_integer() => Lane.t()},
          last_snapshot_index: non_neg_integer(),
          last_snapshot_time: integer()
        }

  # Ra machine callbacks

  @impl true
  def init(%{group_id: group_id}) do
    # Try to load latest snapshot
    case load_latest_snapshot(group_id) do
      {:ok, snapshot} ->
        restore_from_snapshot(snapshot)

      :not_found ->
        cold_start(group_id)
    end
  end

  @impl true
  def apply(meta, {:append_batch, lane_id, frames}, state) do
    lane = Map.fetch!(state.lanes, lane_id)

    {results, new_lane} =
      Enum.map_reduce(frames, lane, fn frame, acc_lane ->
        {session_id, sender_id, recipient_id, kind, content, metadata} = frame

        # Get or bootstrap conversation metadata
        conversation =
          case Map.get(acc_lane.conversations, session_id) do
            nil ->
              # COLD PATH: Bootstrap from DB (only once per session per group lifecycle)
              bootstrap_conversation_from_db(session_id)

            conv ->
              # HOT PATH: Already in RAM, replicated!
              conv
          end

        # Assign sequence (NO DB QUERY!)
        next_seq = conversation.last_seq + 1

        # Build message
        message = %{
          id: Uniq.UUID.uuid7(:slug),
          session_id: session_id,
          seq: next_seq,
          sender_id: sender_id,
          recipient_id: recipient_id,
          kind: kind,
          content: content,
          metadata: metadata,
          inserted_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
        }

        # Append to ETS ring (bounded tail)
        :ets.insert(acc_lane.ring, {next_seq, message})

        # Update conversation metadata
        updated_conv = %{
          conversation
          | last_seq: next_seq,
            last_activity: message.inserted_at
        }

        # Update lane state
        acc_lane = %{
          acc_lane
          | conversations: Map.put(acc_lane.conversations, session_id, updated_conv)
        }

        # Trim ring if over capacity
        acc_lane = trim_ring_if_needed(acc_lane)

        # Emit telemetry
        Fleetlm.Observability.Telemetry.emit_message_throughput()

        # Return session_id, seq, AND message ID for broadcast
        {{session_id, next_seq, message.id}, acc_lane}
      end)

    # Update FSM state
    new_state = put_in(state.lanes[lane_id], new_lane)

    # Check if snapshot needed and update tracking
    {final_state, effects} = maybe_trigger_snapshot(new_state, meta.index)

    {final_state, {:reply, {:ok, results}}, effects}
  end

  @impl true
  def apply(_meta, {:advance_watermark, lane_id, seq}, state) do
    lane = Map.fetch!(state.lanes, lane_id)

    # Update watermark
    new_lane = %{lane | flush_watermark: max(lane.flush_watermark, seq)}

    # Drop ETS entries ≤ watermark (compaction)
    :ets.select_delete(lane.ring, [
      {{:"$1", :_}, [{:"=<", :"$1", seq}], [true]}
    ])

    new_state = put_in(state.lanes[lane_id], new_lane)

    {new_state, :ok}
  end

  @impl true
  def apply(_meta, {:update_sent_seq, lane_id, session_id, seq}, state) do
    # Update last_sent_seq (for StreamWorker recovery)
    # Guard: conversation may not exist yet
    lane = state.lanes[lane_id]

    case Map.get(lane.conversations, session_id) do
      nil ->
        # Conversation not bootstrapped yet, skip update
        {state, :ok}

      conversation ->
        updated_conv = %{conversation | last_sent_seq: max(conversation.last_sent_seq, seq)}
        new_lane = %{lane | conversations: Map.put(lane.conversations, session_id, updated_conv)}
        new_state = put_in(state.lanes[lane_id], new_lane)
        {new_state, :ok}
    end
  end

  @impl true
  def apply(meta, :force_snapshot, state) do
    # Force creation of a snapshot at the current Raft index.
    snapshot_index = meta.index

    new_state = %{
      state
      | last_snapshot_index: snapshot_index,
        last_snapshot_time: monotonic_ms()
    }

    effects = [{:release_cursor, snapshot_index, :snapshot}]

    {new_state, {:reply, :ok}, effects}
  end

  @impl true
  def apply(_meta, :evict_inactive_conversations, state) do
    cutoff = NaiveDateTime.add(NaiveDateTime.utc_now(), -@conversation_ttl_seconds, :second)

    new_lanes =
      for {lane_id, lane} <- state.lanes, into: %{} do
        conversations =
          lane.conversations
          |> Enum.reject(fn {_id, conv} ->
            NaiveDateTime.compare(conv.last_activity, cutoff) == :lt
          end)
          |> Map.new()

        evicted_count = map_size(lane.conversations) - map_size(conversations)

        if evicted_count > 0 do
          Logger.debug(
            "Group #{state.group_id} lane #{lane_id}: Evicted #{evicted_count} inactive conversations"
          )
        end

        {lane_id, %{lane | conversations: conversations}}
      end

    {%{state | lanes: new_lanes}, :ok}
  end

  @impl true
  def apply(_meta, _unknown_command, state) do
    # Catch-all for internal Ra commands (machine_version, noop, etc.)
    {state, :ok}
  end

  @impl true
  def state_enter(:leader, state) do
    Logger.info("Group #{state.group_id}: Elected leader")
    # Start StreamWorkers (handled by supervisor)
    []
  end

  def state_enter(:follower, state) do
    Logger.info("Group #{state.group_id}: Stepped down to follower")
    # Stop StreamWorkers (handled by supervisor)
    []
  end

  def state_enter(_, _state), do: []

  # Snapshot callbacks

  # Ra machine optional callbacks (with defaults)

  @impl true
  def init_aux(_name), do: %{}

  @impl true
  def handle_aux(_state, _cast, _command, aux_state, log_state, _machine_state) do
    {:no_reply, aux_state, log_state}
  end

  @impl true
  def tick(_ts, state) do
    # Emit state metrics for all lanes (every 5s via Ra tick)
    for {lane_id, lane} <- state.lanes do
      in_state_count = :ets.info(lane.ring, :size) || 0
      pending_flush_count = count_pending_flush(lane)
      conversation_count = map_size(lane.conversations)

      Fleetlm.Observability.Telemetry.emit_raft_state(
        state.group_id,
        lane_id,
        in_state_count,
        pending_flush_count,
        conversation_count
      )
    end

    []
  end

  defp count_pending_flush(lane) do
    # Count messages > watermark (pending flush to Postgres)
    :ets.select_count(lane.ring, [
      {{:"$1", :_}, [{:>, :"$1", lane.flush_watermark}], [true]}
    ])
  end

  @impl true
  def overview(_state), do: %{}

  # Version for compatibility
  @impl true
  def version, do: 1

  # Query callbacks

  def query_conversations(state, lane_id) do
    lane = Map.fetch!(state.lanes, lane_id)
    lane.conversations
  end

  def query_messages(state, lane_id, session_id, after_seq) do
    lane = Map.fetch!(state.lanes, lane_id)

    :ets.select(lane.ring, [
      {{:"$1", :"$2"},
       [
         {:>, :"$1", after_seq},
         {:==, {:map_get, :session_id, :"$2"}, session_id}
       ], [:"$2"]}
    ])
    |> Enum.sort_by(& &1.seq)
  end

  def query_unflushed(state) do
    for {lane_id, lane} <- state.lanes, into: %{} do
      watermark = lane.flush_watermark

      messages =
        :ets.select(lane.ring, [
          {{:"$1", :"$2"}, [{:>, :"$1", watermark}], [:"$2"]}
        ])

      {lane_id, messages}
    end
    |> Enum.reject(fn {_, msgs} -> msgs == [] end)
    |> Map.new()
  end

  # Private helpers

  defp cold_start(group_id) do
    lanes =
      for lane_id <- 0..(@num_lanes - 1), into: %{} do
        {lane_id,
         %Lane{
           ring: :ets.new(:ring, [:ordered_set, :public, read_concurrency: true]),
           capacity: @ring_capacity,
           conversations: %{},
           flush_watermark: 0,
           last_flushed_index: 0
         }}
      end

    Logger.info("Group #{group_id}: Cold start (no snapshot found)")

    %__MODULE__{
      group_id: group_id,
      lanes: lanes,
      last_snapshot_index: 0,
      last_snapshot_time: monotonic_ms()
    }
  end

  defp bootstrap_conversation_from_db(session_id) do
    import Ecto.Query

    # Single query with LEFT JOIN to get session + last_seq in one roundtrip
    # CRITICAL: Avoid two DB queries under HEAVY load (causes tail latencies)
    result =
      Repo.one(
        from(s in Session,
          left_join: m in Message,
          on: m.session_id == s.id,
          where: s.id == ^session_id,
          group_by: [s.id, s.user_id, s.agent_id],
          select: %{
            user_id: s.user_id,
            agent_id: s.agent_id,
            last_seq: max(m.seq)
          }
        )
      )

    case result do
      nil ->
        # Session not found - this should not happen in normal operation
        # Create a minimal conversation and log a warning
        Logger.warning("Session #{session_id} not found in DB during bootstrap")

        %Conversation{
          last_seq: 0,
          last_sent_seq: 0,
          user_id: "unknown",
          agent_id: nil,
          last_activity: NaiveDateTime.utc_now()
        }

      %{user_id: user_id, agent_id: agent_id, last_seq: last_seq} ->
        # last_seq will be nil if no messages exist (LEFT JOIN)
        last_seq = last_seq || 0

        Logger.debug(
          "Bootstrapped session #{session_id} from DB: last_seq=#{last_seq}, user_id=#{user_id}"
        )

        %Conversation{
          last_seq: last_seq,
          last_sent_seq: 0,
          user_id: user_id,
          agent_id: agent_id,
          last_activity: NaiveDateTime.utc_now()
        }
    end
  end

  defp trim_ring_if_needed(lane) do
    case :ets.info(lane.ring, :size) do
      size when size > lane.capacity ->
        # Delete oldest entries
        to_delete = size - lane.capacity

        first = :ets.first(lane.ring)
        delete_n_entries(first, lane.ring, to_delete)

        lane

      _ ->
        lane
    end
  end

  defp delete_n_entries(:"$end_of_table", _ring, _n), do: :ok
  defp delete_n_entries(_key, _ring, 0), do: :ok

  defp delete_n_entries(key, ring, n) do
    next = :ets.next(ring, key)
    :ets.delete(ring, key)
    delete_n_entries(next, ring, n - 1)
  end

  defp maybe_trigger_snapshot(state, current_raft_index) do
    bytes_since_last = (current_raft_index - state.last_snapshot_index) * 1024
    time_since_last = monotonic_ms() - state.last_snapshot_time

    cond do
      bytes_since_last >= @snapshot_bytes_threshold ->
        # Update tracking BEFORE returning effect
        new_state = %{
          state
          | last_snapshot_index: current_raft_index,
            last_snapshot_time: monotonic_ms()
        }

        {new_state, [{:release_cursor, current_raft_index, :snapshot}]}

      time_since_last >= @snapshot_interval_ms ->
        # Update tracking BEFORE returning effect
        new_state = %{
          state
          | last_snapshot_index: current_raft_index,
            last_snapshot_time: monotonic_ms()
        }

        {new_state, [{:release_cursor, current_raft_index, :snapshot}]}

      true ->
        {state, []}
    end
  end

  defp load_latest_snapshot(group_id) do
    import Ecto.Query

    case Repo.one(
           from(s in "raft_snapshots",
             where: s.group_id == ^group_id,
             order_by: [desc: s.raft_index],
             limit: 1,
             select: %{
               group_id: s.group_id,
               raft_index: s.raft_index,
               snapshot_data: s.snapshot_data
             }
           )
         ) do
      nil ->
        :not_found

      row ->
        snapshot = :erlang.binary_to_term(row.snapshot_data)
        {:ok, snapshot}
    end
  end

  defp restore_from_snapshot(snapshot) do
    # Rebuild ETS rings from snapshot
    lanes =
      for lane_data <- snapshot.lanes, into: %{} do
        ring = :ets.new(:ring, [:ordered_set, :public, read_concurrency: true])

        # Restore message tail
        for msg <- lane_data.messages do
          :ets.insert(ring, {msg.seq, msg})
        end

        lane = %Lane{
          ring: ring,
          capacity: @ring_capacity,
          conversations: lane_data.conversations,
          flush_watermark: lane_data.flush_watermark,
          last_flushed_index: lane_data.last_flushed_index
        }

        {lane_data.lane_id, lane}
      end

    Logger.info("Group #{snapshot.group_id}: Restored from snapshot index #{snapshot.raft_index}")

    %__MODULE__{
      group_id: snapshot.group_id,
      lanes: lanes,
      last_snapshot_index: snapshot.raft_index,
      last_snapshot_time: monotonic_ms()
    }
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  # Ra snapshot protocol

  def snapshot(state) do
    # Build snapshot with:
    # 1. Conversation metadata (HOT STATE)
    # 2. Message tail > flush_watermark (unflushed only)
    # 3. Watermarks

    snapshot = %{
      group_id: state.group_id,
      raft_index: state.last_snapshot_index,
      timestamp: NaiveDateTime.utc_now(),
      lanes:
        for {lane_id, lane} <- state.lanes do
          # Only snapshot messages > watermark (not yet in Postgres)
          messages =
            :ets.select(lane.ring, [
              {{:"$1", :"$2"}, [{:>, :"$1", lane.flush_watermark}], [:"$2"]}
            ])

          %{
            lane_id: lane_id,
            messages: messages,
            conversations: lane.conversations,
            flush_watermark: lane.flush_watermark,
            last_flushed_index: lane.last_flushed_index
          }
        end
    }

    # Serialize
    binary = :erlang.term_to_binary(snapshot, [:compressed])

    # Write to Postgres
    import Ecto.Query

    Repo.insert_all("raft_snapshots", [
      %{
        group_id: state.group_id,
        raft_index: state.last_snapshot_index,
        snapshot_data: binary,
        created_at: NaiveDateTime.utc_now()
      }
    ])

    # Cleanup old snapshots (keep last 3)
    Repo.delete_all(
      from(s in "raft_snapshots",
        where: s.group_id == ^state.group_id,
        order_by: [desc: s.raft_index],
        offset: 3
      )
    )

    Logger.debug(
      "Group #{state.group_id}: Snapshot created at index #{state.last_snapshot_index}"
    )

    binary
  end

  def restore(snapshot_binary) do
    snapshot = :erlang.binary_to_term(snapshot_binary)
    restore_from_snapshot(snapshot)
  end
end
