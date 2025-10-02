defmodule Fleetlm.Observability.Telemetry do
  @moduledoc """
  Telemetry instrumentation helpers for FleetLM runtime events.

  This module centralises all `:telemetry.execute/3` calls so the rest of the
  application can emit domain-specific metrics without worrying about metric
  backends or state management.
  """

  alias Fleetlm.Runtime.{SessionSupervisor, InboxSupervisor}

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

  @session_drain_event [:fleetlm, :session, :drain]

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
  """
  @spec publish_conversation_active_count() :: :ok
  def publish_conversation_active_count do
    count = SessionSupervisor.active_count()
    :telemetry.execute(@conversation_active_event, %{count: count}, %{scope: :global})
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
