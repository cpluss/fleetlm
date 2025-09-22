defmodule Fleetlm.Chat.Events do
  @moduledoc """
  Handles domain events from the Chat context and broadcasts them as PubSub messages.

  This module provides a clean separation between business logic (Chat context)
  and real-time communication (Phoenix channels/PubSub).
  """

  alias Phoenix.PubSub

  @pubsub Fleetlm.PubSub

  @doc """
  Broadcasts a DM message event to all relevant subscribers.

  Sends notifications to:
  - The DM thread channel (for real-time message display)
  - Both participants' channels (for metadata/notifications)
  """
  def broadcast_dm_message(message) do
    dm_key = message.dm_key

    # Broadcast full message to DM thread subscribers (opt-in real-time)
    PubSub.broadcast(@pubsub, "dm:" <> dm_key, {:dm_message, message})

    # Broadcast metadata to both participants (always-on notifications)
    broadcast_dm_activity_metadata(message)
  end

  @doc """
  Broadcasts DM creation event to both participants.

  Used when a new DM thread is created, ensuring both participants
  are notified even if no message is initially sent.
  """
  def broadcast_dm_created(dm_key, sender_id, recipient_id, initial_message \\ nil) do
    metadata = %{
      event: "dm_activity",
      dm_key: dm_key,
      last_message_at: DateTime.utc_now(),
      last_message_text: initial_message && initial_message.text,
      sender_id: sender_id
    }

    # Notify sender
    sender_metadata = Map.put(metadata, :other_participant_id, recipient_id)
    PubSub.broadcast(@pubsub, "participant:" <> sender_id, {:dm_activity, sender_metadata})

    # Notify recipient
    recipient_metadata = Map.put(metadata, :other_participant_id, sender_id)
    PubSub.broadcast(@pubsub, "participant:" <> recipient_id, {:dm_activity, recipient_metadata})
  end

  @doc """
  Broadcasts a broadcast message to all broadcast subscribers.
  """
  def broadcast_broadcast_message(message) do
    PubSub.broadcast(@pubsub, "broadcast", {:broadcast_message, message})
  end

  # Private helper for DM activity metadata broadcasting
  defp broadcast_dm_activity_metadata(message) do
    dm_key = message.dm_key

    # Parse participants from dm_key format: "user:alice:user:bob"
    case String.split(dm_key, ":") do
      [type_a, id_a, type_b, id_b] when length([type_a, id_a, type_b, id_b]) == 4 ->
        participant_a = "#{type_a}:#{id_a}"
        participant_b = "#{type_b}:#{id_b}"

        metadata_base = %{
          event: "dm_activity",
          dm_key: dm_key,
          last_message_at: message.created_at,
          last_message_text: message.text,
          sender_id: message.sender_id
        }

        # Send to participant A with B as other_participant
        metadata_a = Map.put(metadata_base, :other_participant_id, participant_b)
        PubSub.broadcast(@pubsub, "participant:" <> participant_a, {:dm_activity, metadata_a})

        # Send to participant B with A as other_participant
        metadata_b = Map.put(metadata_base, :other_participant_id, participant_a)
        PubSub.broadcast(@pubsub, "participant:" <> participant_b, {:dm_activity, metadata_b})

      _ ->
        # Invalid dm_key format, log error but don't crash
        require Logger
        Logger.error("Invalid dm_key format for broadcasting: #{dm_key}")
    end
  end
end