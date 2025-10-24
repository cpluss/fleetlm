defmodule Fleetlm.Context.Snapshot do
  @moduledoc """
  Persistent context snapshot stored alongside a conversation.

  Represents the exact transcript slice we hand to the agent on the next
  dispatch, plus strategy bookkeeping data (token estimates, hashes, etc.).
  """

  @enforce_keys [:strategy_id, :token_count]
  defstruct [
    :strategy_id,
    :strategy_version,
    :token_count,
    :last_compacted_seq,
    :last_included_seq,
    summary_messages: [],
    pending_messages: [],
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          strategy_id: String.t(),
          strategy_version: String.t() | nil,
          summary_messages: [map()],
          pending_messages: [map()],
          token_count: non_neg_integer(),
          last_compacted_seq: non_neg_integer() | nil,
          last_included_seq: non_neg_integer() | nil,
          metadata: map()
        }
end
