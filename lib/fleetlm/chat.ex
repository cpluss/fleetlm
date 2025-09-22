defmodule Fleetlm.Chat do
  @moduledoc """
  High-level chat API delegating to the chat runtime dispatcher.
  """

  alias Fleetlm.Chat.{Dispatcher, DmKey, Event}

  ## DM Operations

  def generate_dm_key(participant_a, participant_b) do
    DmKey.build(participant_a, participant_b)
  end

  def create_dm(sender_id, recipient_id, initial_message \\ nil) do
    Dispatcher.open_conversation(sender_id, recipient_id, initial_message)
  end

  def send_dm_message(sender_id, recipient_id, text, metadata \\ %{}) do
    Dispatcher.send_message(%{
      sender_id: sender_id,
      recipient_id: recipient_id,
      text: text,
      metadata: metadata
    })
  end

  def dispatch_message(attrs) when is_map(attrs) do
    cond do
      Map.has_key?(attrs, :recipient_id) or Map.has_key?(attrs, "recipient_id") ->
        Dispatcher.send_message(attrs)

      Map.has_key?(attrs, :dm_key) or Map.has_key?(attrs, "dm_key") ->
        Dispatcher.send_message(attrs)

      Map.has_key?(attrs, :sender_id) or Map.has_key?(attrs, "sender_id") ->
        sender_id = Map.get(attrs, :sender_id) || Map.get(attrs, "sender_id")
        text = Map.get(attrs, :text) || Map.get(attrs, "text")
        metadata = Map.get(attrs, :metadata) || Map.get(attrs, "metadata") || %{}
        Dispatcher.send_broadcast(sender_id, text, metadata)

      true ->
        {:error, :invalid_dm_key}
    end
  end

  def get_dm_conversation_by_key(dm_key, opts \\ []) do
    Dispatcher.convo_history(dm_key, opts)
  end

  def get_dm_conversation(user_a_id, user_b_id, opts \\ []) do
    dm_key = DmKey.build(user_a_id, user_b_id)
    get_dm_conversation_by_key(dm_key, opts)
  end

  def inbox_snapshot(participant_id) do
    Dispatcher.inbox_snapshot(participant_id)
  end

  ## Broadcast operations

  def send_broadcast_message(sender_id, text, metadata \\ %{}) do
    Dispatcher.send_broadcast(sender_id, text, metadata)
  end

  def list_broadcast_messages(opts \\ []) do
    Dispatcher.list_broadcast_messages(opts)
    |> Enum.map(&Event.BroadcastMessage.from_message/1)
  end
end
