defmodule Fleetlm.Runtime.RaftFSM do
  @moduledoc """
  Raft issues commands to each node using an FSM to coordinate
  consistency. We use this to our advantage for message storage and
  sequencing.

  - One FSM per Raft group (256 groups total across cluster).
  - Each group manages 16 lanes for parallel message appends.
  - Each "message append lane" act as a secondary shard layer (beyond groups)
    to avoid hot-groups that cause contention and act as a bottleneck.

  ## State Structure

  State lives entirely in RAM (Raft-replicated 3×) and contains:
  - Conversation metadata (last_seq, user_id, agent_id, etc)
  - Message tail (last 3-5s, ~5000 messages per lane)
  - Flush watermarks (for Raft log compaction)

  It's all optimised to avoid hitting any database while providing a reasonable
  durability guarantee (replication across nodes). We truncate the state
  when we flush messages to the database itself.

  Replication will most likely lead to throughput loss but avoids us having to
  manage everything ourselves, and allows us to lean on battle-tested defaults
  by RAFT.

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

  # TODO: make these configurable, they're hardcoded now for simplicity
  @num_lanes 16
  @ring_capacity 5000
  # TODO: these MUST be configurable, major memory lever
  @snapshot_interval_ms 250
  @snapshot_bytes_threshold 256 * 1024
  # Evict after 1 hour inactivity
  # TODO: configurable, major memory lever too
  @conversation_ttl_seconds 3600

  defmodule Conversation do
    @moduledoc """
    Hot metadata for a session (replicated in Raft state).

    Note that we rebrand this to "conversation" here to avoid conflating sessions <> conversations.
    They're technically related, but a conversation tracks messaging state necessary to generate
    messages, and aren't necessarily unique.

    ## State Machine

    Conversations can be in one of three states:
    - :idle - awaiting user input
    - :catching_up - agent is actively processing messages
    - :compacting - running context summarization (blocks processing)
    """

    @enforce_keys [:last_seq, :user_id, :agent_id, :last_activity]
    defstruct [
      # State machine
      state: :idle,
      work_epoch: 0,
      last_sent_seq: 0,
      pending_user_seq: nil,
      pending_epoch: nil,

      # Compaction state
      tokens_since_summary: 0,
      last_compacted_seq: 0,
      summary: nil,

      # Telemetry tracking
      user_message_sent_at: nil,

      # Core metadata
      last_seq: 0,
      user_id: nil,
      agent_id: nil,
      last_activity: nil
    ]

    @type t :: %__MODULE__{
            state: :idle | :catching_up | :compacting,
            work_epoch: non_neg_integer(),
            last_sent_seq: non_neg_integer(),
            pending_user_seq: non_neg_integer() | nil,
            pending_epoch: non_neg_integer() | nil,
            tokens_since_summary: non_neg_integer(),
            last_compacted_seq: non_neg_integer(),
            summary: map() | nil,
            user_message_sent_at: integer() | nil,
            last_seq: non_neg_integer(),
            user_id: String.t(),
            agent_id: String.t() | nil,
            last_activity: NaiveDateTime.t()
          }
  end

  defmodule Lane do
    @moduledoc """
    One of 16 parallel message streams within a Raft group.

    Each lane contains
     - an ets ring-buffer of messages, keeps memory bounded
     - metadata about each session / conversation
     - flush metadata (ie. how much of this is in the database?)
    """

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

    {results, new_lane, worker_effects} =
      Enum.reduce(frames, {[], lane, []}, fn frame, {results_acc, acc_lane, effects_acc} ->
        {session_id, sender_id, recipient_id, kind, content, metadata} = frame

        # Get or bootstrap conversation metadata
        conversation =
          case Map.get(acc_lane.conversations, session_id) do
            nil ->
              # COLD PATH: Bootstrap from DB (only once per session per group lifecycle)
              # as it's quite expensive.
              bootstrap_conversation_from_db(session_id)

            conv ->
              # HOT PATH: Already in RAM, replicated and we don't need to mess about
              # the database.
              conv
          end

        next_seq = conversation.last_seq + 1

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

        # Append to the ets ring buffer for this lane
        :ets.insert(acc_lane.ring, {next_seq, message})

        updated_conv = %{
          conversation
          | last_seq: next_seq,
            last_activity: message.inserted_at
        }

        # State machine: trigger agent processing if this is a user message
        {updated_conv, new_effects} =
          if sender_id == conversation.user_id and conversation.agent_id != nil and
               sender_id != conversation.agent_id do
            handle_user_message(session_id, updated_conv, next_seq)
          else
            {updated_conv, []}
          end

        acc_lane = %{
          acc_lane
          | conversations: Map.put(acc_lane.conversations, session_id, updated_conv)
        }

        # Trim ring if over capacity
        acc_lane = trim_ring_if_needed(acc_lane)
        Fleetlm.Observability.Telemetry.emit_message_throughput()

        # Accumulate results and effects
        {[{session_id, next_seq, message.id} | results_acc], acc_lane, effects_acc ++ new_effects}
      end)

    # Update FSM state
    new_state = put_in(state.lanes[lane_id], new_lane)

    # Check if snapshot needed and update tracking
    {final_state, snapshot_effects} = maybe_trigger_snapshot(new_state, meta.index)

    # Combine all effects
    all_effects = worker_effects ++ snapshot_effects

    {final_state, {:reply, {:ok, Enum.reverse(results)}}, all_effects}
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
    # Update last_sent_seq
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
  def apply(_meta, {:evict_inactive_conversations}, state) do
    evict_inactive_conversations(state)
  end

  def apply(_meta, :evict_inactive_conversations, state) do
    evict_inactive_conversations(state)
  end

  @impl true
  def apply(_meta, {:agent_caught_up, lane_id, session_id, epoch, sent_seq}, state) do
    lane = state.lanes[lane_id]

    case Map.get(lane.conversations, session_id) do
      %Conversation{work_epoch: ^epoch, state: :catching_up} = conversation ->
        updated =
          conversation
          |> Map.put(:state, :idle)
          |> Map.put(:last_sent_seq, max(conversation.last_sent_seq, sent_seq))
          |> Map.put(:user_message_sent_at, nil)

        {updated, effects} = maybe_start_compaction(session_id, updated)
        {updated, effects} = maybe_process_pending_after_idle(session_id, updated, effects)

        lane = %{lane | conversations: Map.put(lane.conversations, session_id, updated)}
        new_state = put_in(state.lanes[lane_id], lane)

        {new_state, :ok, effects}

      _ ->
        {state, :ok}
    end
  end

  @impl true
  def apply(_meta, {:agent_catchup_failed, lane_id, session_id, epoch, reason}, state) do
    lane = state.lanes[lane_id]

    Logger.error("Agent catch-up failed",
      session_id: session_id,
      lane: lane_id,
      reason: inspect(reason)
    )

    case Map.get(lane.conversations, session_id) do
      %Conversation{work_epoch: ^epoch, state: :catching_up} = conversation ->
        updated = %{
          conversation
          | state: :idle,
            user_message_sent_at: nil
        }

        lane = %{lane | conversations: Map.put(lane.conversations, session_id, updated)}
        new_state = put_in(state.lanes[lane_id], lane)

        {new_state, :ok}

      _ ->
        {state, :ok}
    end
  end

  @impl true
  def apply(_meta, {:compaction_complete, lane_id, session_id, epoch, summary}, state) do
    lane = state.lanes[lane_id]

    case Map.get(lane.conversations, session_id) do
      %Conversation{work_epoch: ^epoch, state: :compacting} = conversation ->
        updated =
          conversation
          |> Map.put(:state, :idle)
          |> Map.put(:summary, summary)
          |> Map.put(:tokens_since_summary, 0)
          |> Map.put(:last_compacted_seq, conversation.last_seq)

        {updated, effects} = maybe_process_pending_after_idle(session_id, updated, [])

        lane = %{lane | conversations: Map.put(lane.conversations, session_id, updated)}
        new_state = put_in(state.lanes[lane_id], lane)

        {new_state, :ok, effects}

      _ ->
        {state, :ok}
    end
  end

  @impl true
  def apply(_meta, {:compaction_failed, lane_id, session_id, epoch, reason}, state) do
    lane = state.lanes[lane_id]

    Logger.error("Compaction failed",
      session_id: session_id,
      lane: lane_id,
      reason: inspect(reason)
    )

    case Map.get(lane.conversations, session_id) do
      %Conversation{work_epoch: ^epoch, state: :compacting} = conversation ->
        updated =
          conversation
          |> Map.put(:state, :idle)

        {updated, effects} = maybe_process_pending_after_idle(session_id, updated, [])

        lane = %{lane | conversations: Map.put(lane.conversations, session_id, updated)}
        new_state = put_in(state.lanes[lane_id], lane)

        {new_state, :ok, effects}

      _ ->
        {state, :ok}
    end
  end

  @impl true
  def apply(_meta, _unknown_command, state) do
    # Catch-all for internal Ra commands (machine_version, noop, etc.)
    {state, :ok}
  end

  @impl true
  def state_enter(:leader, state) do
    Logger.info("Group #{state.group_id}: Elected leader, reconciling workers")

    # Reconcile workers for all conversations in active states
    for {_lane_id, lane} <- state.lanes,
        {session_id, conversation} <- lane.conversations do
      case conversation.state do
        :catching_up ->
          if conversation.agent_id do
            Fleetlm.Webhook.WorkerSupervisor.ensure_catch_up(session_id, %{
              epoch: conversation.work_epoch,
              agent_id: conversation.agent_id,
              user_id: conversation.user_id,
              target_seq: conversation.last_seq,
              last_sent_seq: conversation.last_sent_seq,
              user_message_sent_at: conversation.user_message_sent_at
            })
          end

        :compacting ->
          # Restart compaction worker
          job = build_compaction_job(session_id, conversation)

          Fleetlm.Webhook.WorkerSupervisor.ensure_compaction(session_id, %{
            epoch: conversation.work_epoch,
            job: job
          })

        :idle ->
          :ok
      end
    end

    []
  end

  def state_enter(:follower, state) do
    Logger.info("Group #{state.group_id}: Stepped down to follower, stopping workers")

    # Stop all workers (leader-only execution)
    Fleetlm.Webhook.WorkerSupervisor.stop_all()

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

    Logger.debug("Group #{group_id}: Cold start (no snapshot found)")

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
    # CRITICAL: Avoid two DB queries under HEAVY load as it causes tail latencies
    # when multiple queries back-up against a most likely exhausted postgres pool.
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

  defp handle_user_message(session_id, conversation, seq) do
    if Application.get_env(:fleetlm, :disable_agent_webhooks, false) do
      updated_conversation =
        conversation
        |> Map.put(:state, :idle)
        |> Map.put(:work_epoch, conversation.work_epoch + 1)
        |> Map.put(:last_sent_seq, seq)
        |> Map.put(:user_message_sent_at, nil)

      {updated_conversation, []}
    else
      now = System.monotonic_time(:millisecond)

      case conversation.state do
        :idle ->
          if should_compact?(conversation) do
            epoch = conversation.work_epoch + 1

            conversation =
              conversation
              |> Map.put(:state, :compacting)
              |> Map.put(:work_epoch, epoch)
              |> Map.put(:pending_user_seq, seq)
              |> Map.put(:pending_epoch, epoch + 1)
              |> Map.put(:user_message_sent_at, now)

            job = build_compaction_job(session_id, conversation)

            effects = [
              {:mod_call, Fleetlm.Webhook.WorkerSupervisor, :ensure_compaction,
               [session_id, %{epoch: epoch, job: job}]}
            ]

            {conversation, effects}
          else
            epoch = conversation.work_epoch + 1

            conversation =
              conversation
              |> Map.put(:state, :catching_up)
              |> Map.put(:work_epoch, epoch)
              |> Map.put(:user_message_sent_at, now)

            Logger.debug("Starting catch-up worker",
              session_id: session_id,
              state: :idle,
              target_seq: seq
            )

            effects = catch_up_effects(session_id, conversation, seq)
            {conversation, effects}
          end

        :catching_up ->
          epoch = conversation.work_epoch + 1

          conversation =
            conversation
            |> Map.put(:work_epoch, epoch)
            |> Map.update(:user_message_sent_at, now, & &1)

          Logger.debug("Updating catch-up worker",
            session_id: session_id,
            state: :catching_up,
            target_seq: seq
          )

          effects = catch_up_effects(session_id, conversation, seq)
          {conversation, effects}

        :compacting ->
          conversation =
            conversation
            |> Map.put(:pending_user_seq, seq)
            |> Map.put(:pending_epoch, conversation.pending_epoch || conversation.work_epoch + 1)
            |> Map.put(:user_message_sent_at, now)

          {conversation, []}
      end
    end
  end

  defp catch_up_effects(_session_id, %{agent_id: nil}, _target_seq), do: []

  defp catch_up_effects(session_id, conversation, target_seq) do
    [
      {:mod_call, Fleetlm.Webhook.WorkerSupervisor, :ensure_catch_up,
       [
         session_id,
         %{
           epoch: conversation.work_epoch,
           agent_id: conversation.agent_id,
           user_id: conversation.user_id,
           target_seq: target_seq,
           last_sent_seq: conversation.last_sent_seq,
           user_message_sent_at: conversation.user_message_sent_at
         }
       ]}
    ]
  end

  defp maybe_start_compaction(_session_id, %{agent_id: nil} = conversation) do
    {conversation, []}
  end

  defp maybe_start_compaction(session_id, conversation) do
    if should_compact?(conversation) do
      epoch = conversation.work_epoch + 1

      conversation =
        conversation
        |> Map.put(:state, :compacting)
        |> Map.put(:work_epoch, epoch)

      job = build_compaction_job(session_id, conversation)

      effects = [
        {:mod_call, Fleetlm.Webhook.WorkerSupervisor, :ensure_compaction,
         [session_id, %{epoch: epoch, job: job}]}
      ]

      {conversation, effects}
    else
      {conversation, []}
    end
  end

  defp maybe_process_pending_after_idle(_session_id, %{state: state} = conversation, effects)
       when state != :idle do
    {conversation, effects}
  end

  defp maybe_process_pending_after_idle(session_id, conversation, effects) do
    case conversation.pending_user_seq do
      nil ->
        {%{conversation | pending_epoch: nil}, effects}

      seq ->
        epoch = conversation.pending_epoch || conversation.work_epoch + 1

        conversation =
          conversation
          |> Map.put(:state, :catching_up)
          |> Map.put(:work_epoch, epoch)
          |> Map.put(:pending_user_seq, nil)
          |> Map.put(:pending_epoch, nil)

        {conversation, effects ++ catch_up_effects(session_id, conversation, seq)}
    end
  end

  defp evict_inactive_conversations(state) do
    cutoff = NaiveDateTime.add(NaiveDateTime.utc_now(), -@conversation_ttl_seconds, :second)

    new_lanes =
      Enum.reduce(state.lanes, %{}, fn {lane_id, lane}, acc ->
        {kept, evicted_count} =
          Enum.reduce(lane.conversations, {%{}, 0}, fn {session_id, conversation},
                                                       {keep_acc, count_acc} ->
            if inactive_conversation?(conversation, cutoff) do
              {keep_acc, count_acc + 1}
            else
              {Map.put(keep_acc, session_id, conversation), count_acc}
            end
          end)

        if evicted_count > 0 do
          Logger.debug(
            "Group #{state.group_id} lane #{lane_id}: Evicted #{evicted_count} inactive conversations"
          )
        end

        Map.put(acc, lane_id, %{lane | conversations: kept})
      end)

    {%{state | lanes: new_lanes}, :ok}
  end

  defp inactive_conversation?(%{last_activity: nil}, _cutoff), do: true

  defp inactive_conversation?(%{last_activity: last_activity}, cutoff) do
    NaiveDateTime.compare(last_activity, cutoff) == :lt
  end

  defp should_compact?(conversation) do
    # Hardcoded threshold strategy: compact when tokens exceed 70% of budget
    case Fleetlm.Storage.AgentCache.get(conversation.agent_id) do
      {:ok, agent} ->
        if Map.get(agent, :compaction_enabled, false) do
          budget = Map.get(agent, :compaction_token_budget, 50_000)
          ratio = Map.get(agent, :compaction_trigger_ratio, 0.7)
          threshold = trunc(budget * ratio)

          conversation.tokens_since_summary >= threshold
        else
          false
        end

      _error ->
        false
    end
  end

  defp build_compaction_job(session_id, conversation) do
    case Fleetlm.Storage.AgentCache.get(conversation.agent_id) do
      {:ok, agent} ->
        %{
          session_id: session_id,
          webhook_url: Map.get(agent, :compaction_webhook_url),
          payload: %{
            range_start: conversation.last_compacted_seq + 1,
            range_end: conversation.last_seq
          },
          context: %{
            agent_id: conversation.agent_id,
            user_id: conversation.user_id
          }
        }

      _error ->
        %{}
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
        try do
          snapshot = :erlang.binary_to_term(row.snapshot_data)
          {:ok, snapshot}
        rescue
          e ->
            Logger.error("Failed to deserialize snapshot for group #{group_id}",
              error: Exception.message(e),
              hint: "Stale snapshot format - will cold start instead"
            )

            :not_found
        end
    end
  end

  defp restore_from_snapshot(snapshot) do
    # Rebuild ETS rings from snapshot
    # Snapshot is a plain map (from DB), not a struct
    lanes =
      for lane_data <- Map.get(snapshot, :lanes, []), into: %{} do
        ring = :ets.new(:ring, [:ordered_set, :public, read_concurrency: true])

        # Restore message tail
        for msg <- Map.get(lane_data, :messages, []) do
          :ets.insert(ring, {msg.seq, msg})
        end

        # Restore conversations, handling both old and new formats
        conversations =
          case Map.get(lane_data, :conversations, %{}) do
            convs when is_map(convs) ->
              convs

            _ ->
              Logger.warning("Invalid conversations format in snapshot, using empty map")
              %{}
          end

        lane = %Lane{
          ring: ring,
          capacity: @ring_capacity,
          conversations: conversations,
          flush_watermark: Map.get(lane_data, :flush_watermark, 0),
          last_flushed_index: Map.get(lane_data, :last_flushed_index, 0)
        }

        {Map.get(lane_data, :lane_id), lane}
      end

    group_id = Map.get(snapshot, :group_id)
    raft_index = Map.get(snapshot, :raft_index, 0)

    Logger.debug("Group #{group_id}: Restored from snapshot index #{raft_index}")

    %__MODULE__{
      group_id: group_id,
      lanes: lanes,
      last_snapshot_index: raft_index,
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

    # Serialize, not great to use term to binary compressed in case
    # the snapshot grows insanely large, but we mitigate that by heavily sharding
    # everything so it SHOULD be fine.
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
    try do
      snapshot = :erlang.binary_to_term(snapshot_binary)
      restore_from_snapshot(snapshot)
    rescue
      e ->
        Logger.error("Failed to restore snapshot from binary",
          error: Exception.message(e),
          hint: "Incompatible snapshot format detected"
        )

        # Fall back to cold start with group_id 0 (Ra will provide context)
        cold_start(0)
    end
  end
end
