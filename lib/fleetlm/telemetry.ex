defmodule Fleetlm.Telemetry do
  @moduledoc """
  Telemetry setup for FleetLM application.

  Provides telemetry events for:
  - Database query performance
  - Cache performance
  - Message processing latency
  - PubSub broadcast duration
  """

  require Logger
  alias Telemetry.Metrics

  def setup_metrics do
    Fleetlm.Telemetry.RuntimeCounters.setup()
    :ok
  end

  def attach_handlers do
    events = [
      [:fleetlm, :repo, :query],
      [:fleetlm, :chat, :message, :sent],
      [:fleetlm, :conversation, :started],
      [:fleetlm, :conversation, :stopped],
      [:fleetlm, :inbox, :started],
      [:fleetlm, :inbox, :stopped],
      [:fleetlm, :pubsub, :broadcast]
    ]

    :telemetry.attach_many(
      "fleetlm-telemetry-handler",
      events,
      &handle_event/4,
      %{}
    )
  end

  def handle_event([:fleetlm, :repo, :query], measurements, metadata, _config) do
    duration_ms = System.convert_time_unit(measurements.total_time, :native, :millisecond)

    if duration_ms > 100 do
      Logger.warning("Slow database query: #{duration_ms}ms",
        query: inspect(metadata.query),
        source: metadata.source
      )
    end

    if duration_ms > 10 do
      Logger.debug("Database query: #{duration_ms}ms",
        query: inspect(metadata.query),
        source: metadata.source
      )
    end
  end

  def handle_event([:fleetlm, :chat, :message, :sent], measurements, metadata, _config) do
    duration_ms = measurements[:duration] || 0

    Logger.debug("Message sent: #{duration_ms}ms",
      thread_id: metadata.thread_id,
      sender_id: metadata.sender_id,
      role: metadata.role
    )
  end

  def handle_event([:fleetlm, :pubsub, :broadcast], measurements, metadata, _config) do
    duration_us = measurements[:duration] || 0

    Logger.debug("PubSub broadcast: #{duration_us}μs",
      topic: metadata.topic,
      event: metadata.event
    )
  end

  def handle_event([:fleetlm, :conversation, _event], _measurements, _metadata, _config), do: :ok
  def handle_event([:fleetlm, :inbox, _event], _measurements, _metadata, _config), do: :ok

  def handle_event(event, measurements, metadata, _config) do
    Logger.debug("Unhandled telemetry event: #{inspect(event)}",
      measurements: measurements,
      metadata: metadata
    )
  end

  ## Telemetry emission helpers

  def emit_cache_event(event, cache_name, key, duration_us \\ nil)
      when event in [:hit, :miss] do
    measurements = if duration_us, do: %{duration: duration_us}, else: %{}
    metadata = %{cache: cache_name, key: key}

    :telemetry.execute([:fleetlm, :cache, event], measurements, metadata)
  end

  def emit_message_sent(thread_id, sender_id, role, duration_ms) do
    measurements = %{duration: duration_ms}
    metadata = %{thread_id: thread_id, sender_id: sender_id, role: role}

    :telemetry.execute([:fleetlm, :chat, :message, :sent], measurements, metadata)
  end

  def emit_pubsub_broadcast(topic, event, duration_us) do
    measurements = %{duration: duration_us}
    metadata = %{topic: topic, event: event}

    :telemetry.execute([:fleetlm, :pubsub, :broadcast], measurements, metadata)
  end

  def metrics do
    [
      Metrics.counter("fleetlm_conversations_started_total",
        event_name: [:fleetlm, :conversation, :started],
        measurement: :count,
        tags: [:dm_key]
      ),
      Metrics.counter("fleetlm_conversations_stopped_total",
        event_name: [:fleetlm, :conversation, :stopped],
        measurement: :count,
        tags: [:dm_key, :reason]
      ),
      Metrics.last_value("fleetlm_conversations_active",
        event_name: [:fleetlm, :conversation, :active],
        measurement: :count,
        tags: [:dm_key]
      ),
      Metrics.counter("fleetlm_inboxes_started_total",
        event_name: [:fleetlm, :inbox, :started],
        measurement: :count,
        tags: [:participant_id]
      ),
      Metrics.counter("fleetlm_inboxes_stopped_total",
        event_name: [:fleetlm, :inbox, :stopped],
        measurement: :count,
        tags: [:participant_id, :reason]
      ),
      Metrics.last_value("fleetlm_inboxes_active",
        event_name: [:fleetlm, :inbox, :active],
        measurement: :count,
        tags: [:participant_id]
      )
    ]
  end
end
