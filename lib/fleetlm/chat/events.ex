defmodule Fleetlm.Chat.Events do
  @moduledoc """
  Handles domain events from the Chat runtime and fans them out over PubSub.
  """

  alias Fleetlm.Chat.Event
  alias Phoenix.PubSub

  @pubsub Fleetlm.PubSub

  @doc """
  Broadcast a DM message event to the conversation topic.
  """
  @spec publish_dm_message(Event.DmMessage.t()) :: :ok
  def publish_dm_message(%Event.DmMessage{} = event) do
    PubSub.broadcast(
      @pubsub,
      "dm:" <> event.dm_key,
      {:dm_message, Event.DmMessage.to_payload(event)}
    )

    :ok
  end

  @doc """
  Broadcast a system-wide broadcast message event.
  """
  @spec publish_broadcast_message(Event.BroadcastMessage.t()) :: :ok
  def publish_broadcast_message(%Event.BroadcastMessage{} = event) do
    PubSub.broadcast(@pubsub, "broadcast", {
      :broadcast_message,
      Event.BroadcastMessage.to_payload(event)
    })

    :ok
  end

  @doc """
  Broadcast participant-scoped activity metadata for inbox consumers.
  """
  @spec publish_dm_activity(Event.DmMessage.t(), String.t(), String.t()) :: :ok
  def publish_dm_activity(%Event.DmMessage{} = event, participant_id, other_participant_id) do
    activity = %Event.DmActivity{
      participant_id: participant_id,
      dm_key: event.dm_key,
      other_participant_id: other_participant_id,
      last_sender_id: event.sender_id,
      last_message_text: nil,
      last_message_at: event.created_at,
      unread_count: 0
    }

    PubSub.broadcast(@pubsub, "participant:" <> participant_id, {
      :dm_activity,
      Event.DmActivity.to_payload(activity)
    })

    :ok
  end
end
