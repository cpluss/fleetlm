defmodule Fleetlm.Storage.Entry do
  @moduledoc """
  Immutable representation of a message append written to the slot log.

  Entries capture the minimal data needed to replay or persist the append: the
  owning slot, session id, monotonically increasing sequence number, the
  message ULID, and the full message payload returned by the persistence layer.
  The struct is serialisable and is stored verbatim in `:disk_log` for crash
  recovery and replay.
  """

  alias Fleetlm.Storage.Model.Message

  @type t :: %__MODULE__{
          # The effective disk slot / shard that owns this entry.
          slot: non_neg_integer(),
          # The session id that this entry belongs to.
          session_id: String.t(),
          # The monotonically increasing sequence number for this entry.
          seq: non_neg_integer(),
          # The message ULID.
          message_id: String.t(),
          # The idempotency key for this entry.
          idempotency_key: String.t(),
          # The inserted at timestamp for this entry.
          inserted_at: NaiveDateTime.t(),
          # The full message payload returned by the persistence layer.
          payload: Message.t()
        }

  defstruct [
    :slot,
    :session_id,
    :seq,
    :message_id,
    :idempotency_key,
    :inserted_at,
    :payload
  ]

  @doc """
  Build an entry from a persisted `Message` struct. The entry keeps a copy
  of the struct as-is so downstream consumers (ETS caches, persistence
  replayers) can materialise the message without reaching for the database.
  """
  @spec from_message(non_neg_integer(), non_neg_integer(), String.t(), Message.t()) :: t()
  def from_message(slot, seq, idempotency_key, %Message{} = message) do
    %__MODULE__{
      slot: slot,
      session_id: message.session_id,
      seq: seq,
      message_id: message.id,
      idempotency_key: idempotency_key,
      inserted_at: message.inserted_at,
      payload: message
    }
  end

  @spec to_message(t()) :: Message.t()
  def to_message(entry) do
    %Message{
      id: entry.message_id,
      session_id: entry.session_id,
      seq: entry.seq,
      sender_id: entry.payload.sender_id,
      recipient_id: entry.payload.recipient_id,
      kind: entry.payload.kind,
      content: entry.payload.content,
      metadata: entry.payload.metadata,
      shard_key: entry.payload.shard_key,
      inserted_at: entry.inserted_at
    }
  end
end
