defmodule Fastpaca.Context.Message do
  @moduledoc """
  Sequenced message stored in the Raft message log.
  """

  @enforce_keys [:id, :seq, :role, :parts, :inserted_at]
  defstruct [:id, :seq, :role, :parts, :metadata, :token_count, :inserted_at]

  @type t :: %__MODULE__{
          id: String.t(),
          seq: non_neg_integer(),
          role: String.t(),
          parts: list(),
          metadata: map(),
          token_count: non_neg_integer(),
          inserted_at: NaiveDateTime.t()
        }

  @spec new(non_neg_integer(), String.t(), list(), map(), non_neg_integer()) :: t()
  def new(seq, role, parts, metadata, token_count)
      when is_integer(seq) and seq > 0 and is_binary(role) and is_list(parts) and
             is_map(metadata) and is_integer(token_count) and token_count >= 0 do
    %__MODULE__{
      id: Uniq.UUID.uuid7(:slug),
      seq: seq,
      role: role,
      parts: parts,
      metadata: metadata,
      token_count: token_count,
      inserted_at: NaiveDateTime.utc_now()
    }
  end

  @spec to_log_map(t()) :: map()
  def to_log_map(%__MODULE__{} = message) do
    %{
      role: message.role,
      parts: message.parts,
      metadata: message.metadata,
      token_count: message.token_count,
      seq: message.seq,
      inserted_at: message.inserted_at
    }
  end

  @spec to_api_map(t()) :: map()
  def to_api_map(%__MODULE__{} = message) do
    %{
      id: message.id,
      seq: message.seq,
      role: message.role,
      parts: message.parts,
      metadata: message.metadata,
      token_count: message.token_count,
      inserted_at: NaiveDateTime.to_iso8601(message.inserted_at)
    }
  end
end
