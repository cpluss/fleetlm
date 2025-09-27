defmodule Fleetlm.Runtime.Storage.Entry do
  @moduledoc """
  Immutable representation of a hot-path message append written to the slot log.

  Entries capture the minimal data needed to replay or persist the append: the
  owning slot, session id, monotonically increasing sequence number, the
  message ULID, and the full message payload returned by the persistence layer.
  The struct is serialisable and is stored verbatim in `:disk_log` for crash
  recovery and replay.
  """

  alias Fleetlm.Conversation.ChatMessage

  @type t :: %__MODULE__{
          slot: non_neg_integer(),
          session_id: String.t(),
          seq: non_neg_integer(),
          message_id: String.t(),
          idempotency_key: String.t(),
          inserted_at: NaiveDateTime.t(),
          payload: ChatMessage.t()
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
  Build an entry from a persisted `ChatMessage` struct. The entry keeps a copy
  of the struct as-is so downstream consumers (ETS caches, persistence
  replayers) can materialise the message without reaching for the database.
  """
  @spec from_message(non_neg_integer(), non_neg_integer(), String.t(), ChatMessage.t()) :: t()
  def from_message(slot, seq, idempotency_key, %ChatMessage{} = message) do
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
end
