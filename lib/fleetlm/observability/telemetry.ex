defmodule Fleetlm.Observability.Telemetry do
  @moduledoc """
  Telemetry instrumentation helpers for FleetLM runtime events.

  This module centralises all `:telemetry.execute/3` calls so the rest of the
  application can emit domain-specific metrics without worrying about metric
  backends or state management.
  """

  alias Fleetlm.Runtime.InboxSupervisor

  @session_append_event [:fleetlm, :session, :append]
  @session_fanout_event [:fleetlm, :session, :fanout]
  @session_queue_event [:fleetlm, :session, :queue, :length]
  @disk_log_append_event [:fleetlm, :slot, :disk_log, :append]

  @conversation_started_event [:fleetlm, :conversation, :started]
  @conversation_stopped_event [:fleetlm, :conversation, :stopped]
  @conversation_active_event [:fleetlm, :conversation, :active_count]

  @inbox_started_event [:fleetlm, :inbox, :started]
  @inbox_stopped_event [:fleetlm, :inbox, :stopped]
  @inbox_active_event [:fleetlm, :inbox, :active_count]

  @message_sent_event [:fleetlm, :chat, :message, :sent]
  @cache_events [:fleetlm, :cache]
  @pubsub_broadcast_event [:fleetlm, :pubsub, :broadcast]

  @storage_read_event [:fleetlm, :storage, :read]
  @storage_flush_event [:fleetlm, :storage, :flush]
  @storage_recovery_event [:fleetlm, :storage, :recovery]
  @storage_append_event [:fleetlm, :storage, :append]

  @agent_webhook_event [:fleetlm, :agent, :webhook, :dispatch]
  @agent_parse_error_event [:fleetlm, :agent, :parse_error]
  @agent_validation_error_event [:fleetlm, :agent, :validation_error]
  @agent_debounce_event [:fleetlm, :agent, :debounce]
  @agent_e2e_latency_event [:fleetlm, :agent, :e2e_latency]
  @agent_dispatch_drop_event [:fleetlm, :agent, :dispatch, :drop]
  @agent_stream_chunk_event [:fleetlm, :agent, :stream, :chunk]
  @agent_stream_finalized_event [:fleetlm, :agent, :stream, :finalized]

  @session_drain_event [:fleetlm, :session, :drain]

  @message_throughput_event [:fleetlm, :message, :throughput]

  # Raft telemetry events
  @raft_append_event [:fleetlm, :raft, :append]
  @raft_read_event [:fleetlm, :raft, :read]
  @raft_state_event [:fleetlm, :raft, :state]
  @raft_flush_event [:fleetlm, :raft, :flush]

  @spec measure_session_append(String.t(), %{optional(atom()) => term()}, (-> {term(), map()})) ::
          term()
  def measure_session_append(session_id, metadata \\ %{}, fun) when is_function(fun, 0) do
    base_metadata =
      metadata
      |> Map.put(:session_id, session_id)

    :telemetry.execute(@session_append_event ++ [:start], %{}, base_metadata)

    start = System.monotonic_time()

    try do
      {result, extra_metadata} = fun.()

      finalize_session_append(start, base_metadata, result, extra_metadata)
    rescue
      exception ->
        stop_session_append_with_exception(
          start,
          base_metadata,
          exception.__struct__,
          exception,
          __STACKTRACE__
        )
    catch
      kind, reason ->
        stop_session_append_with_exception(start, base_metadata, kind, reason, __STACKTRACE__)
    end
  end

  @spec record_session_queue_depth(String.t(), non_neg_integer()) :: :ok
  def record_session_queue_depth(session_id, queue_len)
      when is_integer(queue_len) and queue_len >= 0 do
    metadata = %{session_id: session_id}
    measurements = %{length: queue_len}

    :telemetry.execute(@session_queue_event, measurements, metadata)
  end

  @spec record_session_fanout(String.t(), atom(), non_neg_integer(), %{optional(atom()) => term()}) ::
          :ok
  def record_session_fanout(session_id, type, duration_us, metadata \\ %{})
      when is_atom(type) and is_integer(duration_us) and duration_us >= 0 do
    meta =
      metadata
      |> Map.put(:session_id, session_id)
      |> Map.put(:type, type)

    measurements = %{duration: duration_us, count: 1}
    :telemetry.execute(@session_fanout_event, measurements, meta)
  end

  @spec record_disk_log_append(non_neg_integer(), non_neg_integer(), %{optional(atom()) => term()}) ::
          :ok
  def record_disk_log_append(slot, duration_us, metadata \\ %{})
      when is_integer(slot) and slot >= 0 and is_integer(duration_us) and duration_us >= 0 do
    meta = Map.put(metadata, :slot, slot)
    measurements = %{duration: duration_us, count: 1}
    :telemetry.execute(@disk_log_append_event, measurements, meta)
  end

  @doc """
  Record that a conversation process started and update the active count gauge.
  """
  @spec conversation_started(String.t()) :: :ok
  def conversation_started(dm_key) when is_binary(dm_key) do
    :telemetry.execute(@conversation_started_event, %{count: 1}, %{dm_key: dm_key})
    publish_conversation_active_count()
  end

  @doc """
  Record that a conversation process stopped and update the active count gauge.
  """
  @spec conversation_stopped(String.t(), term()) :: :ok
  def conversation_stopped(dm_key, reason) when is_binary(dm_key) do
    metadata = %{dm_key: dm_key, reason: format_reason(reason)}

    :telemetry.execute(@conversation_stopped_event, %{count: 1}, metadata)
    publish_conversation_active_count()
  end

  @doc """
  Emit the current number of active conversation processes as a gauge.

  NOTE: In Raft architecture, there are no per-session processes.
  Conversations live in Raft state (ETS rings). This metric is deprecated.
  """
  @spec publish_conversation_active_count() :: :ok
  def publish_conversation_active_count do
    # With Raft, no per-session processes exist
    # Emit 0 to maintain metric compatibility
    :telemetry.execute(@conversation_active_event, %{count: 0}, %{scope: :global})
  end

  @doc """
  Record that an inbox process started and update the active count gauge.
  """
  @spec inbox_started(String.t()) :: :ok
  def inbox_started(user_id) when is_binary(user_id) do
    :telemetry.execute(@inbox_started_event, %{count: 1}, %{user_id: user_id})
    publish_inbox_active_count()
  end

  @doc """
  Record that an inbox process stopped and update the active count gauge.
  """
  @spec inbox_stopped(String.t(), term()) :: :ok
  def inbox_stopped(user_id, reason) when is_binary(user_id) do
    metadata = %{user_id: user_id, reason: format_reason(reason)}

    :telemetry.execute(@inbox_stopped_event, %{count: 1}, metadata)
    publish_inbox_active_count()
  end

  @doc """
  Emit the current number of active inbox processes as a gauge.
  """
  @spec publish_inbox_active_count() :: :ok
  def publish_inbox_active_count do
    count = InboxSupervisor.active_count()
    :telemetry.execute(@inbox_active_event, %{count: count}, %{scope: :global})
  end

  @doc """
  Record that a chat message was sent.
  """
  @spec message_sent(String.t(), String.t(), String.t(), %{optional(:role) => String.t()}) :: :ok
  def message_sent(dm_key, sender_id, recipient_id, metadata \\ %{})
      when is_binary(dm_key) and is_binary(sender_id) and is_binary(recipient_id) do
    role = normalize_role(metadata)

    tags = %{
      dm_key: dm_key,
      sender_id: sender_id,
      recipient_id: recipient_id,
      role: role
    }

    :telemetry.execute(@message_sent_event, %{count: 1}, tags)
  end

  @doc """
  Emit cache hit/miss telemetry events, optionally including a duration.
  """
  @spec emit_cache_event(:hit | :miss, atom(), term(), integer() | nil) :: :ok
  def emit_cache_event(event, cache_name, key, duration_us \\ nil)
      when event in [:hit, :miss] and is_atom(cache_name) do
    measurements =
      %{count: 1}
      |> maybe_put_duration(duration_us)

    metadata = %{cache: cache_name, key: key}

    :telemetry.execute(@cache_events ++ [event], measurements, metadata)
  end

  @doc """
  Emit a telemetry event describing a pub/sub broadcast.
  """
  @spec emit_pubsub_broadcast(String.t(), atom(), integer()) :: :ok
  def emit_pubsub_broadcast(topic, event, duration_us)
      when is_binary(topic) and is_atom(event) and is_integer(duration_us) do
    measurements = %{duration: duration_us, count: 1}
    metadata = %{topic: topic, event: event}

    :telemetry.execute(@pubsub_broadcast_event, measurements, metadata)
  end

  @doc """
  Emit storage read telemetry - tracks whether messages came from disk log or database.
  """
  @spec emit_storage_read(String.t(), non_neg_integer(), atom(), non_neg_integer(), integer()) ::
          :ok
  def emit_storage_read(session_id, slot, source, message_count, duration_us)
      when is_binary(session_id) and is_integer(slot) and source in [:disk_log, :database] and
             is_integer(message_count) and is_integer(duration_us) do
    measurements = %{duration: duration_us, count: message_count}

    metadata = %{
      session_id: session_id,
      slot: slot,
      source: source
    }

    :telemetry.execute(@storage_read_event, measurements, metadata)
  end

  @doc """
  Emit storage flush telemetry.
  """
  @spec emit_storage_flush(non_neg_integer(), atom(), non_neg_integer(), integer()) :: :ok
  def emit_storage_flush(slot, result, message_count, duration_us)
      when is_integer(slot) and result in [:ok, :error] and is_integer(message_count) and
             is_integer(duration_us) do
    measurements = %{duration: duration_us, count: message_count}
    metadata = %{slot: slot, result: result}

    :telemetry.execute(@storage_flush_event, measurements, metadata)
  end

  @doc """
  Emit storage recovery telemetry - CRITICAL for data loss detection.
  """
  @spec emit_storage_recovery(
          non_neg_integer(),
          atom(),
          non_neg_integer(),
          non_neg_integer()
        ) :: :ok
  def emit_storage_recovery(slot, recovery_type, recovered_entries, lost_bytes)
      when is_integer(slot) and recovery_type in [:corruption, :not_a_log_file, :repair_failed] and
             is_integer(recovered_entries) and is_integer(lost_bytes) do
    measurements = %{recovered_entries: recovered_entries, lost_bytes: lost_bytes}

    metadata = %{
      slot: slot,
      type: recovery_type
    }

    :telemetry.execute(@storage_recovery_event, measurements, metadata)
  end

  @doc """
  Emit storage append telemetry.
  """
  @spec emit_storage_append(String.t(), non_neg_integer(), atom(), integer()) :: :ok
  def emit_storage_append(session_id, slot, result, duration_us)
      when is_binary(session_id) and is_integer(slot) and result in [:ok, :error] and
             is_integer(duration_us) do
    measurements = %{duration: duration_us, count: 1}
    metadata = %{session_id: session_id, slot: slot, result: result}

    :telemetry.execute(@storage_append_event, measurements, metadata)
  end

  @doc """
  Emit session drain telemetry - CRITICAL for graceful shutdown tracking.
  """
  @spec emit_session_drain(
          atom(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          integer()
        ) ::
          :ok
  def emit_session_drain(reason, attempted, succeeded, failed, duration_ms)
      when reason in [:rebalance, :shutdown, :sigterm] and is_integer(attempted) and
             is_integer(succeeded) and is_integer(failed) and is_integer(duration_ms) do
    measurements = %{
      duration: duration_ms,
      sessions_attempted: attempted,
      sessions_succeeded: succeeded,
      sessions_failed: failed
    }

    metadata = %{reason: reason, node: Node.self()}

    :telemetry.execute(@session_drain_event, measurements, metadata)
  end

  @doc """
  Emit agent webhook dispatch telemetry - tracks every webhook call.
  """
  @spec emit_agent_webhook(String.t(), String.t(), atom(), integer(), keyword()) :: :ok
  def emit_agent_webhook(agent_id, session_id, result, duration_us, opts \\ [])
      when is_binary(agent_id) and is_binary(session_id) and result in [:ok, :error] and
             is_integer(duration_us) do
    error_type = Keyword.get(opts, :error_type)
    status_code = Keyword.get(opts, :status_code)
    message_count = Keyword.get(opts, :message_count, 0)

    measurements = %{duration: duration_us, message_count: message_count}

    metadata =
      %{agent_id: agent_id, session_id: session_id, result: result}
      |> maybe_put(:error_type, error_type)
      |> maybe_put(:status_code, status_code)

    :telemetry.execute(@agent_webhook_event, measurements, metadata)
  end

  @doc """
  Emit agent dispatch drop telemetry - tracks permanent webhook failures.
  """
  @spec emit_agent_dispatch_drop(String.t(), String.t(), term(), term()) :: :ok
  def emit_agent_dispatch_drop(agent_id, session_id, reason, error \\ nil)
      when is_binary(agent_id) and is_binary(session_id) do
    measurements = %{count: 1}

    metadata =
      %{agent_id: agent_id, session_id: session_id}
      |> maybe_put(:reason, normalize_drop_reason(reason))
      |> maybe_put(:error, normalize_drop_error(error))

    :telemetry.execute(@agent_dispatch_drop_event, measurements, metadata)
  end

  @doc """
  Emit agent parse error telemetry - CRITICAL protocol violation tracking.
  """
  @spec emit_agent_parse_error(String.t(), String.t(), atom(), String.t()) :: :ok
  def emit_agent_parse_error(agent_id, session_id, error_type, line)
      when is_binary(agent_id) and is_binary(session_id) and is_atom(error_type) and
             is_binary(line) do
    measurements = %{count: 1}

    metadata = %{
      agent_id: agent_id,
      session_id: session_id,
      error_type: error_type,
      line: String.slice(line, 0, 200)
    }

    :telemetry.execute(@agent_parse_error_event, measurements, metadata)
  end

  @doc """
  Emit agent validation error telemetry - edge validation failures.
  """
  @spec emit_agent_validation_error(String.t(), String.t(), atom()) :: :ok
  def emit_agent_validation_error(agent_id, session_id, validation_error)
      when is_binary(agent_id) and is_binary(session_id) and is_atom(validation_error) do
    measurements = %{count: 1}

    metadata = %{
      agent_id: agent_id,
      session_id: session_id,
      validation: validation_error
    }

    :telemetry.execute(@agent_validation_error_event, measurements, metadata)
  end

  @doc """
  Emit agent debounce telemetry - tracks time-to-webhook and batch size.
  """
  @spec emit_agent_debounce(String.t(), String.t(), integer(), non_neg_integer(), integer()) ::
          :ok
  def emit_agent_debounce(agent_id, session_id, debounce_delay_us, batched_messages, window_ms)
      when is_binary(agent_id) and is_binary(session_id) and is_integer(debounce_delay_us) and
             is_integer(batched_messages) and is_integer(window_ms) do
    measurements = %{
      delay: debounce_delay_us,
      batched_messages: batched_messages
    }

    metadata = %{
      agent_id: agent_id,
      session_id: session_id,
      window_ms: window_ms
    }

    :telemetry.execute(@agent_debounce_event, measurements, metadata)
  end

  @doc """
  Emit end-to-end agent latency telemetry - from message sent to agent response received.
  """
  @spec emit_agent_e2e_latency(String.t(), String.t(), integer(), non_neg_integer()) :: :ok
  def emit_agent_e2e_latency(agent_id, session_id, latency_us, message_count)
      when is_binary(agent_id) and is_binary(session_id) and is_integer(latency_us) and
             is_integer(message_count) do
    measurements = %{
      duration: latency_us,
      message_count: message_count
    }

    metadata = %{
      agent_id: agent_id,
      session_id: session_id
    }

    :telemetry.execute(@agent_e2e_latency_event, measurements, metadata)
  end

  @doc """
  Emit message throughput telemetry - messages/second across all sessions.
  """
  @spec emit_message_throughput() :: :ok
  def emit_message_throughput do
    measurements = %{count: 1}
    :telemetry.execute(@message_throughput_event, measurements, %{})
  end

  @doc """
  Emit agent stream chunk telemetry - tracks chunk types and errors.
  """
  @spec emit_agent_stream_chunk(String.t(), String.t(), String.t(), atom()) :: :ok
  def emit_agent_stream_chunk(agent_id, session_id, chunk_type, result)
      when is_binary(agent_id) and is_binary(session_id) and is_binary(chunk_type) and
             result in [:ok, :error] do
    measurements = %{count: 1}

    metadata = %{
      agent_id: agent_id,
      session_id: session_id,
      chunk_type: chunk_type,
      result: result
    }

    :telemetry.execute(@agent_stream_chunk_event, measurements, metadata)
  end

  @doc """
  Emit agent stream finalized telemetry - tracks message assembly completion.

  The `termination` parameter indicates how the stream ended:
  - `:finish` - normal completion (agent sent "finish" chunk)
  - `:abort` - early cancellation (agent sent "abort" chunk)
  """
  @spec emit_agent_stream_finalized(String.t(), String.t(), atom(), non_neg_integer()) :: :ok
  def emit_agent_stream_finalized(agent_id, session_id, termination, part_count)
      when is_binary(agent_id) and is_binary(session_id) and
             termination in [:finish, :abort] and is_integer(part_count) do
    measurements = %{part_count: part_count}

    metadata = %{
      agent_id: agent_id,
      session_id: session_id,
      termination: termination
    }

    :telemetry.execute(@agent_stream_finalized_event, measurements, metadata)
  end

  @doc """
  Emit Raft append telemetry - tracks message append operations to Raft groups.

  Records:
  - Append latency (time to commit to quorum)
  - Success/timeout/error status
  - Group and lane identification

  This is CRITICAL for validating Raft performance meets <150ms p99 target.
  """
  @spec emit_raft_append(atom(), non_neg_integer(), non_neg_integer(), non_neg_integer()) :: :ok
  def emit_raft_append(status, group_id, lane, duration_us)
      when status in [:ok, :timeout, :error] and is_integer(group_id) and is_integer(lane) and
             is_integer(duration_us) do
    measurements = %{
      duration: duration_us,
      count: 1
    }

    metadata = %{
      status: status,
      group_id: group_id,
      lane: lane
    }

    :telemetry.execute(@raft_append_event, measurements, metadata)
  end

  @doc """
  Emit Raft read telemetry - tracks message read operations from Raft state.

  Records:
  - Read latency
  - Read path (tail_only = hot path, tail_and_db = cold path)
  - Message count returned

  This validates the hybrid read strategy (Raft tail + Postgres fallback).
  """
  @spec emit_raft_read(atom(), non_neg_integer(), non_neg_integer(), non_neg_integer()) :: :ok
  def emit_raft_read(path, group_id, message_count, duration_us)
      when path in [:tail_only, :tail_and_db] and is_integer(group_id) and
             is_integer(message_count) and is_integer(duration_us) do
    measurements = %{
      duration: duration_us,
      message_count: message_count
    }

    metadata = %{
      path: path,
      group_id: group_id
    }

    :telemetry.execute(@raft_read_event, measurements, metadata)
  end

  @doc """
  Emit Raft state telemetry - tracks in-memory state size and flush metrics.

  Records per-group:
  - In-state message count (messages in ETS rings, not yet flushed)
  - Pending flush count (messages > watermark)
  - Conversation count (hot metadata cached in Raft state)
  - Ring fill percentage (for backpressure monitoring)

  This is CRITICAL for detecting memory pressure and flush lag.
  """
  @spec emit_raft_state(
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) ::
          :ok
  def emit_raft_state(group_id, lane, in_state_count, pending_flush_count, conversation_count)
      when is_integer(group_id) and is_integer(lane) and is_integer(in_state_count) and
             is_integer(pending_flush_count) and is_integer(conversation_count) do
    measurements = %{
      in_state_count: in_state_count,
      pending_flush_count: pending_flush_count,
      conversation_count: conversation_count,
      ring_fill_pct: min(100, div(in_state_count * 100, 5000))
    }

    metadata = %{
      group_id: group_id,
      lane: lane
    }

    :telemetry.execute(@raft_state_event, measurements, metadata)
  end

  @doc """
  Emit Raft flush telemetry - tracks background flush operations to Postgres.

  Records:
  - Flush latency
  - Messages flushed count
  - Status (ok/error)

  This validates the write-behind strategy is keeping up with ingestion rate.
  """
  @spec emit_raft_flush(atom(), non_neg_integer(), non_neg_integer(), non_neg_integer()) :: :ok
  def emit_raft_flush(status, group_id, messages_flushed, duration_us)
      when status in [:ok, :error] and is_integer(group_id) and is_integer(messages_flushed) and
             is_integer(duration_us) do
    measurements = %{
      duration: duration_us,
      messages_flushed: messages_flushed
    }

    metadata = %{
      status: status,
      group_id: group_id
    }

    :telemetry.execute(@raft_flush_event, measurements, metadata)
  end

  defp normalize_drop_reason(nil), do: nil
  defp normalize_drop_reason(reason) when is_atom(reason), do: reason

  defp normalize_drop_reason({:http_status, status} = tuple) when is_integer(status) do
    tuple
  end

  defp normalize_drop_reason(reason) do
    inspect(reason, limit: 10, printable_limit: 200)
  end

  defp normalize_drop_error(nil), do: nil
  defp normalize_drop_error(reason) when is_binary(reason), do: String.slice(reason, 0, 200)

  defp normalize_drop_error(reason) do
    reason
    |> inspect(limit: 10, printable_limit: 200)
    |> String.slice(0, 200)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_role(%{role: role}) when is_binary(role) or is_atom(role), do: to_string(role)
  defp normalize_role(%{"role" => role}) when is_binary(role), do: role
  defp normalize_role(_), do: raise(ArgumentError, "missing or invalid :role in metadata")

  defp format_reason(%_{} = value) do
    if function_exported?(value.__struct__, :message, 1) do
      Exception.message(value)
    else
      inspect(value)
    end
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason({:shutdown, inner}), do: format_reason(inner)
  defp format_reason(other), do: inspect(other)

  defp finalize_session_append(start, base_metadata, result, extra_metadata) do
    duration_us = duration_us(start)

    metadata =
      base_metadata
      |> Map.merge(extra_metadata || %{})
      |> Map.put(:status, status_from_result(result))
      |> maybe_put_error(result)

    measurements = %{duration: duration_us, count: 1}
    :telemetry.execute(@session_append_event ++ [:stop], measurements, metadata)
    result
  end

  defp stop_session_append_with_exception(start, base_metadata, kind, reason, stacktrace) do
    duration_us = duration_us(start)

    metadata =
      base_metadata
      |> Map.put(:status, :exception)
      |> Map.put(:error_kind, to_string(kind))
      |> Map.put(:error, format_reason(reason))

    measurements = %{duration: duration_us, count: 1}
    :telemetry.execute(@session_append_event ++ [:stop], measurements, metadata)

    :erlang.raise(kind, reason, stacktrace)
  end

  defp status_from_result({:ok, _}), do: :ok
  defp status_from_result(:ok), do: :ok
  defp status_from_result({:error, _}), do: :error
  defp status_from_result({:error, _, _}), do: :error
  defp status_from_result(_), do: :ok

  defp maybe_put_error(metadata, {:error, reason}) do
    Map.put(metadata, :error, format_reason(reason))
  end

  defp maybe_put_error(metadata, _), do: metadata

  defp duration_us(start) do
    start
    |> elapsed()
    |> System.convert_time_unit(:native, :microsecond)
  end

  defp elapsed(start), do: System.monotonic_time() - start

  defp maybe_put_duration(measurements, nil), do: measurements

  defp maybe_put_duration(measurements, duration_us) do
    Map.put(measurements, :duration, duration_us)
  end
end
