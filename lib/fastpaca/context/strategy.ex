defmodule Fastpaca.Context.Strategy do
  @moduledoc """
  Behaviour for context compaction strategies.

  Strategies define HOW to compact a context snapshot when the
  trigger conditions are met (token budget * trigger ratio exceeded).
  """

  alias Fastpaca.Context.Snapshot

  @doc """
  Compact a snapshot according to the strategy.

  Returns:
  - `{:ok, compacted_snapshot, from_seq, to_seq}` - compaction succeeded
  - `{:noop, snapshot}` - no compaction needed yet
  - `{:error, reason}` - compaction failed
  """
  @callback compact(snapshot :: Snapshot.t(), config :: map()) ::
              {:ok, Snapshot.t(), non_neg_integer(), non_neg_integer()}
              | {:noop, Snapshot.t()}
              | {:error, term()}
end
