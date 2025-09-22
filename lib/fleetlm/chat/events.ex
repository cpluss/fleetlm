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
  Broadcast inbox activity updates to a participant channel.
  """
  @spec publish_dm_activity(Event.DmActivity.t()) :: :ok
  def publish_dm_activity(%Event.DmActivity{} = event) do
    PubSub.broadcast(@pubsub, "participant:" <> event.participant_id, {
      :dm_activity,
      Event.DmActivity.to_payload(event)
    })

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
end
