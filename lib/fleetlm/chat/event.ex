defmodule Fleetlm.Chat.Event do
  @moduledoc """
  Domain events emitted by the chat runtime.
  """

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
            participant_id: String.t(),
            dm_key: String.t(),
            other_participant_id: String.t(),
            last_sender_id: String.t() | nil,
            last_message_text: String.t() | nil,
            last_message_at: DateTime.t() | NaiveDateTime.t() | nil,
            unread_count: non_neg_integer()
          }

    defstruct [
      :participant_id,
      :dm_key,
      :other_participant_id,
      :last_sender_id,
      :last_message_text,
      :last_message_at,
      unread_count: 0
    ]

    def to_payload(%__MODULE__{} = event) do
      %{
        "participant_id" => event.participant_id,
        "dm_key" => event.dm_key,
        "other_participant_id" => event.other_participant_id,
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
end
