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

  def attach_handlers do
    events = [
      # Database telemetry
      [:fleetlm, :repo, :query],

      # Cache telemetry
      [:fleetlm, :cache, :hit],
      [:fleetlm, :cache, :miss],

      # Chat telemetry
      [:fleetlm, :chat, :message, :sent],
      [:fleetlm, :thread_server, :tick],

      # PubSub telemetry
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

  def handle_event([:fleetlm, :cache, event], measurements, metadata, _config)
      when event in [:hit, :miss] do
    Logger.debug("Cache #{event}: #{metadata.cache} - #{metadata.key}",
      duration_us: measurements[:duration]
    )
  end

  def handle_event([:fleetlm, :chat, :message, :sent], measurements, metadata, _config) do
    duration_ms = measurements[:duration] || 0

    Logger.debug("Message sent: #{duration_ms}ms",
      thread_id: metadata.thread_id,
      sender_id: metadata.sender_id,
      role: metadata.role
    )
  end

  def handle_event([:fleetlm, :thread_server, :tick], measurements, metadata, _config) do
    duration_ms = measurements[:duration] || 0

    Logger.debug("ThreadServer tick: #{duration_ms}ms",
      thread_id: metadata.thread_id,
      participant_id: metadata.participant_id,
      status: metadata.status
    )
  end

  def handle_event([:fleetlm, :pubsub, :broadcast], measurements, metadata, _config) do
    duration_us = measurements[:duration] || 0

    Logger.debug("PubSub broadcast: #{duration_us}μs",
      topic: metadata.topic,
      event: metadata.event
    )
  end

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

  def emit_thread_tick(thread_id, participant_id, status, duration_ms) do
    measurements = %{duration: duration_ms}
    metadata = %{thread_id: thread_id, participant_id: participant_id, status: status}

    :telemetry.execute([:fleetlm, :thread_server, :tick], measurements, metadata)
  end

  def emit_pubsub_broadcast(topic, event, duration_us) do
    measurements = %{duration: duration_us}
    metadata = %{topic: topic, event: event}

    :telemetry.execute([:fleetlm, :pubsub, :broadcast], measurements, metadata)
  end
end
