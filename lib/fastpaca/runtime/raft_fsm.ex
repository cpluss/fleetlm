defmodule Fastpaca.Runtime.RaftFSM do
  @moduledoc """
  Raft state machine for Fastpaca context management.

  ## Architecture

  - 256 Raft groups × 3 replicas
  - Each group: 16 lanes for parallel writes
  - Context metadata cached in Raft state (no DB queries on hot path)
  - Background flush to Postgres (optional, disabled by default)

  ## State Structure

  State lives entirely in RAM (Raft-replicated 3×):
  - Context metadata (last_seq, snapshot, policy, trigger settings)
  - Message tail (last ~5000 messages per lane in ETS ring)
  - Flush watermarks (for Raft log compaction)

  ## Write Path

  1. Client → append_batch command
  2. Check trigger (used_tokens > budget * ratio)
  3. If triggered → compact command (mutates snapshot)
  4. Broadcast events: "message" and "compaction"
  5. ACK to client

  ## Read Path

  - GET /contexts/:id/context → return pre-computed snapshot (pure read)
  - No compaction logic on read path
  """

  @behaviour :ra_machine

  require Logger

  alias Fastpaca.Context.{Manager, Snapshot}
  alias Fastpaca.Storage.Model.Context, as: ContextModel

  # Configuration
  @num_lanes 16
  @ring_capacity 5000
  @snapshot_interval_ms 250
  @snapshot_bytes_threshold 256 * 1024
  @context_ttl_seconds 3600

  defmodule Context do
    @moduledoc """
    Hot context metadata (replicated in Raft state).

    Minimal structure - no agent state machine, no user tracking.
    """

    @enforce_keys [:context_id, :last_seq, :last_activity]
    defstruct [
      # Identity
      context_id: nil,

      # Message tracking
      last_seq: 0,
      last_activity: nil,

      # Trigger (WHEN to compact)
      token_budget: 1_000_000,
      trigger_ratio: 0.7,

      # Policy (HOW to compact)
      policy: %{},

      # Compaction state
      snapshot: nil,

      # Versioning
      version: 0,

      # Metadata
      metadata: %{}
    ]

    @type t :: %__MODULE__{
            context_id: String.t(),
            last_seq: non_neg_integer(),
            last_activity: NaiveDateTime.t(),
            token_budget: pos_integer(),
            trigger_ratio: float(),
            policy: map(),
            snapshot: Snapshot.t() | nil,
            version: non_neg_integer(),
            metadata: map()
          }
  end

  defmodule Lane do
    @moduledoc """
    One of 16 parallel message streams within a Raft group.
    """

    @enforce_keys [:ring, :capacity, :contexts, :flush_watermark, :last_flushed_index]
    defstruct [:ring, :capacity, :contexts, :flush_watermark, :last_flushed_index]

    @type t :: %__MODULE__{
            ring: :ets.tid(),
            capacity: pos_integer(),
            contexts: %{String.t() => Context.t()},
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
    Logger.info("Initializing Raft FSM for group #{group_id}")
    cold_start(group_id)
  end

  @impl true
  def apply(meta, {:append_batch, lane_id, frames}, state) do
    lane = Map.fetch!(state.lanes, lane_id)

    {results, new_lane, all_effects} =
      Enum.reduce(frames, {[], lane, []}, fn frame, {results_acc, acc_lane, effects_acc} ->
        {context_id, role, parts, metadata} = frame

        # Get or bootstrap context
        context = get_or_bootstrap_context(acc_lane, context_id)
        next_seq = context.last_seq + 1

        # Build message
        message = %{
          id: Uniq.UUID.uuid7(:slug),
          context_id: context_id,
          seq: next_seq,
          role: role,
          parts: parts,
          metadata: metadata,
          inserted_at: NaiveDateTime.utc_now()
        }

        # Insert into ETS ring
        :ets.insert(acc_lane.ring, {next_seq, message})

        # Add message to snapshot
        updated_snapshot = add_message_to_snapshot(context.snapshot, message)

        # Calculate tokens
        token_count = count_tokens(updated_snapshot)

        # Update context
        updated_context = %{
          context
          | last_seq: next_seq,
            snapshot: %{updated_snapshot | token_count: token_count},
            last_activity: NaiveDateTime.utc_now()
        }

        # Check trigger and maybe compact
        threshold = context.token_budget * context.trigger_ratio
        {final_context, compact_effects} =
          if token_count > threshold do
            case apply_compaction_strategy(updated_context) do
              {:ok, compacted_context} ->
                # Compaction succeeded
                effect = {
                  :mod_call,
                  Phoenix.PubSub,
                  :broadcast,
                  [
                    Fastpaca.PubSub,
                    "context:#{context_id}",
                    {:compaction,
                     %{
                       version: compacted_context.version,
                       strategy: get_in(context.policy, [:strategy]) || "unknown"
                     }}
                  ]
                }

                {compacted_context, [effect]}

              {:error, _reason} ->
                # Set needs_compaction flag
                flagged =
                  put_in(
                    updated_context.snapshot.metadata[:needs_compaction],
                    true
                  )

                {flagged, []}
            end
          else
            {updated_context, []}
          end

        # Broadcast message event
        message_effect = {
          :mod_call,
          Phoenix.PubSub,
          :broadcast,
          [
            Fastpaca.PubSub,
            "context:#{context_id}",
            {:message,
             %{
               seq: next_seq,
               role: role,
               parts: parts,
               version: final_context.version
             }}
          ]
        }

        # Update lane
        new_contexts = Map.put(acc_lane.contexts, context_id, final_context)
        new_lane = %{acc_lane | contexts: new_contexts}

        # Trim ring if needed
        new_lane = trim_ring_if_needed(new_lane)

        # Accumulate
        new_effects = [message_effect | compact_effects] ++ effects_acc
        {[{context_id, next_seq, message.id} | results_acc], new_lane, new_effects}
      end)

    # Update state
    new_state = put_in(state.lanes[lane_id], new_lane)

    # Maybe trigger snapshot
    {final_state, snapshot_effects} = maybe_trigger_snapshot(new_state, meta.index)

    all_effects = all_effects ++ snapshot_effects

    {final_state, {:reply, {:ok, Enum.reverse(results)}}, all_effects}
  end

  @impl true
  def apply(_meta, {:compact, lane_id, context_id, from_seq, to_seq, replacement_messages}, state) do
    lane = Map.fetch!(state.lanes, lane_id)

    case Map.get(lane.contexts, context_id) do
      nil ->
        # Context not found
        {state, {:reply, {:error, :context_not_found}}}

      context ->
        # Replace snapshot range
        new_snapshot = %{
          context.snapshot
          | summary_messages: replacement_messages,
            pending_messages:
              Enum.filter(context.snapshot.pending_messages || [], &(&1.seq > to_seq)),
            last_compacted_seq: to_seq,
            token_count: count_tokens(replacement_messages)
        }

        # Bump version
        new_context = %{
          context
          | snapshot: new_snapshot,
            version: context.version + 1
        }

        # Update lane
        new_contexts = Map.put(lane.contexts, context_id, new_context)
        new_lane = %{lane | contexts: new_contexts}
        new_state = put_in(state.lanes[lane_id], new_lane)

        # Broadcast compaction event
        effect = {
          :mod_call,
          Phoenix.PubSub,
          :broadcast,
          [
            Fastpaca.PubSub,
            "context:#{context_id}",
            {:compaction,
             %{
               version: new_context.version,
               compacted_range: [from_seq, to_seq]
             }}
          ]
        }

        {new_state, {:reply, {:ok, new_context.version}}, [effect]}
    end
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
  def apply(meta, :force_snapshot, state) do
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
  def apply(_meta, :evict_inactive_contexts, state) do
    evict_inactive_contexts(state)
  end

  # State queries (read-only)

  @doc """
  Query messages from a lane (for replay/list).
  """
  def query_messages(state, lane_id, context_id, after_seq) do
    lane = Map.get(state.lanes, lane_id)

    if lane do
      :ets.select(lane.ring, [
        {{:"$1", :"$2"},
         [
           {:"==", {:map_get, :context_id, :"$2"}, context_id},
           {:">", :"$1", after_seq}
         ], [:"$2"]}
      ])
    else
      []
    end
  end

  @doc """
  Query all contexts in a lane.
  """
  def query_contexts(state, lane_id) do
    case Map.get(state.lanes, lane_id) do
      nil -> %{}
      lane -> lane.contexts
    end
  end

  # Private helpers

  defp cold_start(group_id) do
    Logger.info("Cold start for group #{group_id}")

    lanes =
      for lane_id <- 0..(@num_lanes - 1), into: %{} do
        ring = :ets.new(:"raft_ring_#{group_id}_#{lane_id}", [:ordered_set, :public])

        lane = %Lane{
          ring: ring,
          capacity: @ring_capacity,
          contexts: %{},
          flush_watermark: 0,
          last_flushed_index: 0
        }

        {lane_id, lane}
      end

    %__MODULE__{
      group_id: group_id,
      lanes: lanes,
      last_snapshot_index: 0,
      last_snapshot_time: monotonic_ms()
    }
  end

  defp get_or_bootstrap_context(lane, context_id) do
    case Map.get(lane.contexts, context_id) do
      nil ->
        # Bootstrap from DB (cold path)
        bootstrap_context_from_db(context_id)

      context ->
        context
    end
  end

  defp bootstrap_context_from_db(context_id) do
    # Try to load from Postgres
    case Fastpaca.Repo.get(ContextModel, context_id) do
      nil ->
        # Context doesn't exist - create minimal default
        Logger.warning("Context #{context_id} not found in DB, creating default")

        %Context{
          context_id: context_id,
          last_seq: 0,
          last_activity: NaiveDateTime.utc_now(),
          token_budget: 1_000_000,
          trigger_ratio: 0.7,
          policy: %{strategy: "last_n", config: %{limit: 200}},
          snapshot: %Snapshot{
            summary_messages: [],
            pending_messages: [],
            token_count: 0,
            last_compacted_seq: 0,
            last_included_seq: 0,
            metadata: %{}
          },
          version: 0,
          metadata: %{}
        }

      db_context ->
        # Load from DB
        %Context{
          context_id: context_id,
          last_seq: 0,
          last_activity: NaiveDateTime.utc_now(),
          token_budget: db_context.token_budget,
          trigger_ratio: db_context.trigger_ratio,
          policy: db_context.policy,
          snapshot: %Snapshot{
            summary_messages: [],
            pending_messages: [],
            token_count: 0,
            last_compacted_seq: 0,
            last_included_seq: 0,
            metadata: %{}
          },
          version: db_context.version,
          metadata: db_context.metadata
        }
    end
  end

  defp add_message_to_snapshot(nil, message) do
    # First message, create snapshot
    %Snapshot{
      summary_messages: [],
      pending_messages: [message],
      token_count: 0,
      last_compacted_seq: 0,
      last_included_seq: message.seq,
      metadata: %{}
    }
  end

  defp add_message_to_snapshot(snapshot, message) do
    %{
      snapshot
      | pending_messages: (snapshot.pending_messages || []) ++ [message],
        last_included_seq: message.seq
    }
  end

  defp count_tokens(snapshot) when is_struct(snapshot, Snapshot) do
    all_messages = (snapshot.summary_messages || []) ++ (snapshot.pending_messages || [])
    count_tokens(all_messages)
  end

  defp count_tokens(messages) when is_list(messages) do
    # Simple token estimation: ~4 chars per token
    Enum.reduce(messages, 0, fn msg, acc ->
      text =
        Enum.reduce(msg.parts || [], "", fn part, text_acc ->
          case part do
            %{"type" => "text", "text" => t} -> text_acc <> t
            %{type: "text", text: t} -> text_acc <> t
            _ -> text_acc
          end
        end)

      acc + div(String.length(text), 4)
    end)
  end

  defp apply_compaction_strategy(context) do
    strategy_module = get_strategy_module(context.policy[:strategy] || "last_n")

    case strategy_module.compact(context.snapshot, context.policy[:config] || %{}) do
      {:ok, compacted_snapshot, from_seq, to_seq} ->
        new_snapshot = %{
          compacted_snapshot
          | last_compacted_seq: to_seq,
            metadata: Map.delete(compacted_snapshot.metadata, :needs_compaction)
        }

        {:ok, %{context | snapshot: new_snapshot, version: context.version + 1}}

      {:noop, _snapshot} ->
        # Strategy decided not to compact yet
        {:error, :noop}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_strategy_module("last_n"), do: Fastpaca.Context.Strategies.LastN
  defp get_strategy_module("skip_parts"), do: Fastpaca.Context.Strategies.SkipParts
  defp get_strategy_module("manual"), do: Fastpaca.Context.Strategies.Manual
  defp get_strategy_module(_), do: Fastpaca.Context.Strategies.LastN

  defp trim_ring_if_needed(lane) do
    current_size = :ets.info(lane.ring, :size)

    if current_size > lane.capacity do
      # Delete oldest entries
      to_delete = current_size - lane.capacity
      oldest_keys = :ets.first(lane.ring)

      Enum.reduce(1..to_delete, oldest_keys, fn _, key ->
        next_key = :ets.next(lane.ring, key)
        :ets.delete(lane.ring, key)
        next_key
      end)
    end

    lane
  end

  defp maybe_trigger_snapshot(state, current_index) do
    time_since_last = monotonic_ms() - state.last_snapshot_time
    index_since_last = current_index - state.last_snapshot_index

    should_snapshot =
      time_since_last >= @snapshot_interval_ms or
        index_since_last >= @snapshot_bytes_threshold

    if should_snapshot do
      new_state = %{
        state
        | last_snapshot_index: current_index,
          last_snapshot_time: monotonic_ms()
      }

      effects = [{:release_cursor, current_index, :snapshot}]
      {new_state, effects}
    else
      {state, []}
    end
  end

  defp evict_inactive_contexts(state) do
    now = NaiveDateTime.utc_now()
    ttl_seconds = @context_ttl_seconds

    new_lanes =
      Enum.reduce(state.lanes, state.lanes, fn {lane_id, lane}, acc_lanes ->
        new_contexts =
          Enum.reject(lane.contexts, fn {_id, context} ->
            diff = NaiveDateTime.diff(now, context.last_activity, :second)
            diff > ttl_seconds
          end)
          |> Enum.into(%{})

        new_lane = %{lane | contexts: new_contexts}
        Map.put(acc_lanes, lane_id, new_lane)
      end)

    new_state = %{state | lanes: new_lanes}
    {new_state, :ok}
  end

  defp monotonic_ms do
    System.monotonic_time(:millisecond)
  end
end
