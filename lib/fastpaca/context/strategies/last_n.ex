defmodule Fastpaca.Context.Strategies.LastN do
  @moduledoc """
  Keeps only the last N messages in the context.

  Config:
  - `limit`: Maximum number of messages to keep (default: 200)

  When triggered, drops older messages beyond the limit.
  """

  @behaviour Fastpaca.Context.Strategy

  alias Fastpaca.Context.Snapshot

  @default_limit 200

  @impl true
  def compact(snapshot, config) do
    limit = Map.get(config, :limit, Map.get(config, "limit", @default_limit))

    all_messages = (snapshot.summary_messages || []) ++ (snapshot.pending_messages || [])

    if length(all_messages) > limit do
      # Drop oldest messages
      kept_messages = Enum.take(all_messages, -limit)
      dropped_messages = Enum.take(all_messages, length(all_messages) - limit)

      from_seq = hd(all_messages).seq
      to_seq = List.last(dropped_messages).seq

      new_snapshot = %{
        snapshot
        | summary_messages: [],
          pending_messages: kept_messages,
          last_compacted_seq: to_seq
      }

      {:ok, new_snapshot, from_seq, to_seq}
    else
      # Not enough messages yet
      {:noop, snapshot}
    end
  end
end
