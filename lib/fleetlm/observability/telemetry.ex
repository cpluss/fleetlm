defmodule Fleetlm.Observability.Telemetry do
  @moduledoc """
  Telemetry instrumentation helpers for FleetLM runtime events.

  This module centralises all `:telemetry.execute/3` calls so the rest of the
  application can emit domain-specific metrics without worrying about metric
  backends or state management.
  """

  alias Fleetlm.Chat.{ConversationSupervisor, InboxSupervisor}

  @conversation_started_event [:fleetlm, :conversation, :started]
  @conversation_stopped_event [:fleetlm, :conversation, :stopped]
  @conversation_active_event [:fleetlm, :conversation, :active_count]

  @inbox_started_event [:fleetlm, :inbox, :started]
  @inbox_stopped_event [:fleetlm, :inbox, :stopped]
  @inbox_active_event [:fleetlm, :inbox, :active_count]

  @message_sent_event [:fleetlm, :chat, :message, :sent]
  @cache_events [:fleetlm, :cache]
  @pubsub_broadcast_event [:fleetlm, :pubsub, :broadcast]

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
    count = ConversationSupervisor.active_count()
    :telemetry.execute(@conversation_active_event, %{count: count}, %{scope: :global})
  end

  @doc """
  Record that an inbox process started and update the active count gauge.
  """
  @spec inbox_started(String.t()) :: :ok
  def inbox_started(participant_id) when is_binary(participant_id) do
    :telemetry.execute(@inbox_started_event, %{count: 1}, %{participant_id: participant_id})
    publish_inbox_active_count()
  end

  @doc """
  Record that an inbox process stopped and update the active count gauge.
  """
  @spec inbox_stopped(String.t(), term()) :: :ok
  def inbox_stopped(participant_id, reason) when is_binary(participant_id) do
    metadata = %{participant_id: participant_id, reason: format_reason(reason)}

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
  @spec message_sent(String.t(), String.t(), String.t(), map()) :: :ok
  def message_sent(dm_key, sender_id, recipient_id, metadata \\ %{})
      when is_binary(dm_key) and is_binary(sender_id) and is_binary(recipient_id) do
    tags =
      metadata
      |> normalize_message_metadata()
      |> Map.merge(%{
        dm_key: dm_key,
        sender_id: sender_id,
        recipient_id: recipient_id
      })

    :telemetry.execute(@message_sent_event, %{count: 1}, tags)
  end

  @doc """
  Emit cache hit/miss telemetry events, optionally including a duration.
  """
  @spec emit_cache_event(:hit | :miss, atom(), term(), integer() | nil) :: :ok
  def emit_cache_event(event, cache_name, key, duration_us \\ nil)
      when event in [:hit, :miss] and is_atom(cache_name) do
    measurements = if duration_us, do: %{duration: duration_us}, else: %{}
    metadata = %{cache: cache_name, key: key}

    :telemetry.execute(@cache_events ++ [event], measurements, metadata)
  end

  @doc """
  Emit a telemetry event describing a pub/sub broadcast.
  """
  @spec emit_pubsub_broadcast(String.t(), atom(), integer()) :: :ok
  def emit_pubsub_broadcast(topic, event, duration_us)
      when is_binary(topic) and is_atom(event) and is_integer(duration_us) do
    measurements = %{duration: duration_us}
    metadata = %{topic: topic, event: event}

    :telemetry.execute(@pubsub_broadcast_event, measurements, metadata)
  end

  defp normalize_message_metadata(metadata) when is_map(metadata) do
    role =
      metadata
      |> Map.get(:role) || Map.get(metadata, "role") || "unknown"

    %{role: to_string(role)}
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason({:shutdown, inner}), do: format_reason(inner)
  defp format_reason(_), do: "unknown"
end
