defmodule Fleetlm.Chat.Events do
  @moduledoc """
  Domain event definitions and PubSub fanout helpers for the chat runtime.
  """

  alias Fleetlm.Chat.InboxSupervisor
  alias Fleetlm.Chat.InboxServer
  alias Phoenix.PubSub

  @pubsub Fleetlm.PubSub

  defmodule DmMessage do
    @moduledoc """
    Event emitted whenever a DM message is persisted.
    """

    @type t :: %__MODULE__{
            id: String.t(),
            dm_key: String.t(),
            sender_id: String.t(),
            recipient_id: String.t(),
            text: String.t() | nil,
            metadata: map(),
            created_at: DateTime.t()
          }

    defstruct [:id, :dm_key, :sender_id, :recipient_id, :text, :metadata, :created_at]

    def from_message(message) do
      %__MODULE__{
        id: message.id,
        dm_key: message.dm_key,
        sender_id: message.sender_id,
        recipient_id: message.recipient_id,
        text: message.text,
        metadata: message.metadata || %{},
        created_at: message.created_at
      }
    end

    def to_payload(%__MODULE__{} = event) do
      %{
        "id" => event.id,
        "dm_key" => event.dm_key,
        "sender_id" => event.sender_id,
        "recipient_id" => event.recipient_id,
        "text" => event.text,
        "metadata" => event.metadata || %{},
        "created_at" => encode_datetime(event.created_at)
      }
    end

    defp encode_datetime(nil), do: nil
    defp encode_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
    defp encode_datetime(%NaiveDateTime{} = naive), do: NaiveDateTime.to_iso8601(naive)
    defp encode_datetime(value) when is_binary(value), do: value
  end

  defmodule DmActivity do
    @moduledoc """
    Event emitted to a participant's inbox whenever a DM changes.
    """

    @type t :: %__MODULE__{
            sender_id: String.t(),
            dm_key: String.t(),
            last_sender_id: String.t() | nil,
            last_message_text: String.t() | nil,
            last_message_at: DateTime.t() | NaiveDateTime.t() | nil,
            unread_count: non_neg_integer()
          }

    defstruct [
      :sender_id,
      :dm_key,
      :last_sender_id,
      :last_message_text,
      :last_message_at,
      unread_count: 0
    ]

    def to_payload(%__MODULE__{} = event) do
      %{
        "sender_id" => event.sender_id,
        "dm_key" => event.dm_key,
        "last_sender_id" => event.last_sender_id,
        "last_message_text" => event.last_message_text,
        "last_message_at" => encode_datetime(event.last_message_at),
        "unread_count" => event.unread_count
      }
    end

    defp encode_datetime(nil), do: nil
    defp encode_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
    defp encode_datetime(%NaiveDateTime{} = naive), do: NaiveDateTime.to_iso8601(naive)
    defp encode_datetime(value) when is_binary(value), do: value
  end

  defmodule BroadcastMessage do
    @moduledoc """
    Event emitted whenever a broadcast message is persisted.
    """

    @type t :: %__MODULE__{
            id: String.t(),
            sender_id: String.t(),
            text: String.t() | nil,
            metadata: map(),
            created_at: DateTime.t()
          }

    defstruct [:id, :sender_id, :text, :metadata, :created_at]

    def from_message(message) do
      %__MODULE__{
        id: message.id,
        sender_id: message.sender_id,
        text: message.text,
        metadata: message.metadata || %{},
        created_at: message.created_at
      }
    end

    def to_payload(%__MODULE__{} = event) do
      %{
        "id" => event.id,
        "sender_id" => event.sender_id,
        "text" => event.text,
        "metadata" => event.metadata || %{},
        "created_at" => encode_datetime(event.created_at)
      }
    end

    defp encode_datetime(nil), do: nil
    defp encode_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
    defp encode_datetime(%NaiveDateTime{} = naive), do: NaiveDateTime.to_iso8601(naive)
    defp encode_datetime(value) when is_binary(value), do: value
  end

  @doc """
  Broadcast a DM message event to the conversation topic.
  """
  @spec publish_dm_message(DmMessage.t()) :: :ok
  def publish_dm_message(%DmMessage{} = event) do
    PubSub.broadcast(
      @pubsub,
      "conversation:" <> event.dm_key,
      {:dm_message, DmMessage.to_payload(event)}
    )

    :ok
  end

  @doc """
  Broadcast a system-wide broadcast message event.
  """
  @spec publish_broadcast_message(BroadcastMessage.t()) :: :ok
  def publish_broadcast_message(%BroadcastMessage{} = event) do
    PubSub.broadcast(@pubsub, "broadcast", {
      :broadcast_message,
      BroadcastMessage.to_payload(event)
    })

    :ok
  end

  @doc """
  Broadcast participant-scoped activity metadata for inbox consumers.
  """
  @spec publish_dm_activity(DmMessage.t()) :: :ok
  def publish_dm_activity(%DmMessage{} = event) do
    activity = %DmActivity{
      sender_id: event.sender_id,
      dm_key: event.dm_key,
      last_sender_id: event.sender_id,
      last_message_text: event.text,
      last_message_at: event.created_at,
      unread_count: 0
    }

    Enum.each([event.sender_id, event.recipient_id], fn participant_id ->
      case InboxSupervisor.has_started?(participant_id) do
        true -> InboxServer.enqueue_activity(participant_id, activity)
        false -> :skip
      end
    end)
  end
end
