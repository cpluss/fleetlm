defmodule Fastpaca.Runtime.RaftFSM do
  @moduledoc """
  Minimal Raft state machine for Fastpaca. Stores contexts containing both the
  full message log and the LLM view.
  """

  @behaviour :ra_machine

  alias Fastpaca.Context
  alias Fastpaca.Context.Config

  @num_lanes 16

  defmodule Lane do
    @moduledoc false
    defstruct contexts: %{}
  end

  defstruct [:group_id, :lanes]

  @impl true
  def init(%{group_id: group_id}) do
    lanes = for lane <- 0..(@num_lanes - 1), into: %{}, do: {lane, %Lane{}}
    %__MODULE__{group_id: group_id, lanes: lanes}
  end

  @impl true
  def apply(
        _meta,
        {:upsert_context, lane_id, context_id, %Config{} = config, status, metadata},
        state
      ) do
    lane = Map.fetch!(state.lanes, lane_id)

    context =
      case Map.get(lane.contexts, context_id) do
        nil ->
          Context.new(context_id, config, status: status, metadata: metadata)

        %Context{} = existing ->
          Context.update(existing, config, status: status, metadata: metadata)
      end

    new_lane = %{lane | contexts: Map.put(lane.contexts, context_id, context)}
    new_state = put_in(state.lanes[lane_id], new_lane)

    reply = %{
      id: context.id,
      status: context.status,
      token_budget: context.config.token_budget,
      trigger_ratio: context.config.trigger_ratio,
      policy: context.config.policy,
      version: context.version,
      last_seq: context.last_seq,
      archived_seq: context.archived_seq,
      metadata: context.metadata,
      inserted_at: NaiveDateTime.to_iso8601(context.inserted_at),
      updated_at: NaiveDateTime.to_iso8601(context.updated_at)
    }

    {new_state, {:reply, {:ok, reply}}}
  end

  @impl true
  def apply(_meta, {:append_batch, lane_id, context_id, inbound_messages, opts}, state) do
    lane = Map.fetch!(state.lanes, lane_id)

    with {:ok, context} <- fetch_context(lane, context_id),
         :ok <- ensure_active(context),
         :ok <- guard_version(context, opts[:if_version]) do
      {updated_context, appended, flag} = Context.append(context, inbound_messages)

      new_lane = %{lane | contexts: Map.put(lane.contexts, context_id, updated_context)}
      new_state = put_in(state.lanes[lane_id], new_lane)

      reply =
        Enum.map(appended, fn %{seq: seq, token_count: tokens} ->
          %{
            context_id: context_id,
            seq: seq,
            version: updated_context.version,
            token_count: tokens
          }
        end)

      effects = build_effects(context_id, appended, updated_context, flag)

      {new_state, {:reply, {:ok, reply}}, effects}
    else
      {:error, reason} -> {state, {:reply, {:error, reason}}}
    end
  end

  @impl true
  def apply(_meta, {:compact, lane_id, context_id, replacement, opts}, state) do
    lane = Map.fetch!(state.lanes, lane_id)

    with {:ok, context} <- fetch_context(lane, context_id),
         :ok <- guard_version(context, opts[:if_version]) do
      {updated_context, _llm} = Context.compact(context, replacement)

      new_lane = %{lane | contexts: Map.put(lane.contexts, context_id, updated_context)}
      new_state = put_in(state.lanes[lane_id], new_lane)

      effect = broadcast_compaction(context_id, updated_context)

      {new_state, {:reply, {:ok, updated_context.version}}, [effect]}
    else
      {:error, reason} -> {state, {:reply, {:error, reason}}}
    end
  end

  @impl true
  def apply(_meta, :force_snapshot, state) do
    {state, {:reply, :ok}}
  end

  @impl true
  def apply(_meta, {:ack_archived, lane_id, context_id, upto_seq}, state) do
    lane = Map.fetch!(state.lanes, lane_id)

    with {:ok, context} <- fetch_context(lane, context_id) do
      {updated_context, trimmed} = Context.persist_ack(context, upto_seq)

      new_lane = %{lane | contexts: Map.put(lane.contexts, context_id, updated_context)}
      new_state = put_in(state.lanes[lane_id], new_lane)

      # Emit telemetry about archival lag and trim
      tail_size = length(updated_context.message_log.entries)

      Fastpaca.Observability.Telemetry.archive_ack_applied(
        context_id,
        updated_context.last_seq,
        updated_context.archived_seq,
        trimmed,
        updated_context.retention.tail_keep,
        tail_size,
        updated_context.llm_context.token_count
      )

      {new_state,
       {:reply, {:ok, %{archived_seq: updated_context.archived_seq, trimmed: trimmed}}}}
    else
      {:error, reason} -> {state, {:reply, {:error, reason}}}
    end
  end

  # ---------------------------------------------------------------------------
  # Queries
  # ---------------------------------------------------------------------------

  @doc """
  Query messages from the tail (newest) with offset-based pagination.

  Optimized for backward iteration starting from most recent messages.
  """
  def query_messages_tail(state, lane_id, context_id, offset, limit) do
    with {:ok, lane} <- Map.fetch(state.lanes, lane_id),
         {:ok, context} <- fetch_context(lane, context_id) do
      Context.messages_tail(context, offset, limit)
    else
      _ -> []
    end
  end

  @doc """
  Query unarchived messages (seq > archived_seq) up to `limit`.

  Returns messages in chronological order (oldest to newest in the result).
  """
  def query_unarchived(state, lane_id, context_id, limit) do
    with {:ok, lane} <- Map.fetch(state.lanes, lane_id),
         {:ok, %Context{} = context} <- fetch_context(lane, context_id) do
      context.message_log
      |> Map.get(:entries, [])
      # entries are newest-first; take while strictly newer than archive boundary
      |> Enum.take_while(fn %{seq: seq} -> seq > context.archived_seq end)
      |> Enum.reverse()
      |> Enum.take(limit)
    else
      _ -> []
    end
  end

  def query_context(state, lane_id, context_id) do
    with {:ok, lane} <- Map.fetch(state.lanes, lane_id),
         {:ok, context} <- fetch_context(lane, context_id) do
      {:ok, context}
    else
      _ -> {:error, :context_not_found}
    end
  end

  def query_contexts(state, lane_id) do
    case Map.fetch(state.lanes, lane_id) do
      {:ok, %Lane{contexts: contexts}} -> contexts
      _ -> %{}
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp fetch_context(%Lane{contexts: contexts}, context_id) do
    case Map.get(contexts, context_id) do
      nil -> {:error, :context_not_found}
      context -> {:ok, context}
    end
  end

  defp ensure_active(%Context{status: :active}), do: :ok
  defp ensure_active(_), do: {:error, :context_tombstoned}

  defp guard_version(_context, nil), do: :ok
  defp guard_version(%Context{version: version}, expected) when version == expected, do: :ok

  defp guard_version(%Context{version: version}, _expected),
    do: {:error, {:version_conflict, version}}

  defp build_effects(context_id, messages, context, flag) do
    message_events =
      Enum.map(messages, fn message ->
        {
          :mod_call,
          Phoenix.PubSub,
          :broadcast,
          [
            Fastpaca.PubSub,
            "context:#{context_id}",
            {:message, message_payload(message, context)}
          ]
        }
      end)

    archive_event =
      {
        :mod_call,
        Fastpaca.Archive,
        :append_messages,
        [context_id, messages]
      }

    if flag == :compact do
      message_events ++ [broadcast_compaction(context_id, context), archive_event]
    else
      message_events ++ [archive_event]
    end
  end

  defp message_payload(message, %Context{} = context) do
    Map.put(message, :version, context.version)
  end

  defp broadcast_compaction(context_id, %Context{} = context) do
    {
      :mod_call,
      Phoenix.PubSub,
      :broadcast,
      [
        Fastpaca.PubSub,
        "context:#{context_id}",
        {:compaction, %{version: context.version, token_count: context.llm_context.token_count}}
      ]
    }
  end
end
