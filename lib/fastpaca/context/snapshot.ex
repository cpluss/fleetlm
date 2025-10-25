defmodule Fastpaca.Context.Snapshot do
  @moduledoc """
  Context snapshot - the pre-computed window for LLMs.

  Contains:
  - summary_messages: Compacted/summarized older messages
  - pending_messages: Recent uncompacted messages
  - token_count: Estimated token usage
  - Compaction metadata
  """

  @enforce_keys [:token_count]
  defstruct [
    :token_count,
    :last_compacted_seq,
    :last_included_seq,
    summary_messages: [],
    pending_messages: [],
    metadata: %{}
  ]

  @type t :: %__MODULE__{
          summary_messages: [map()],
          pending_messages: [map()],
          token_count: non_neg_integer(),
          last_compacted_seq: non_neg_integer() | nil,
          last_included_seq: non_neg_integer() | nil,
          metadata: map()
        }
end
