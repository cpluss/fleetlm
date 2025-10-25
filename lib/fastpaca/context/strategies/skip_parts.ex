defmodule Fastpaca.Context.Strategies.SkipParts do
  @moduledoc """
  Drops messages with specific part types (e.g., tool_call, tool_result),
  then applies last_n logic.

  Config:
  - `limit`: Maximum number of messages to keep (default: 200)
  - `skip_types`: List of part types to skip (default: ["tool_call", "tool_result"])

  Useful for agents that generate huge tool outputs.
  """

  @behaviour Fastpaca.Context.Strategy

  alias Fastpaca.Context.Snapshot

  @default_limit 200
  @default_skip_types ["tool_call", "tool_result"]

  @impl true
  def compact(snapshot, config) do
    limit = Map.get(config, :limit, Map.get(config, "limit", @default_limit))

    skip_types =
      Map.get(config, :skip_types, Map.get(config, "skip_types", @default_skip_types))

    all_messages = (snapshot.summary_messages || []) ++ (snapshot.pending_messages || [])

    # Filter out messages with skipped part types
    filtered_messages =
      Enum.reject(all_messages, fn msg ->
        Enum.any?(msg.parts || [], fn part ->
          part_type = Map.get(part, :type) || Map.get(part, "type")
          part_type in skip_types
        end)
      end)

    if length(filtered_messages) > limit do
      # Apply last_n to filtered messages
      kept_messages = Enum.take(filtered_messages, -limit)
      dropped_messages = Enum.take(filtered_messages, length(filtered_messages) - limit)

      from_seq = hd(all_messages).seq
      to_seq = List.last(dropped_messages).seq

      new_snapshot = %{
        snapshot
        | summary_messages: [],
          pending_messages: kept_messages,
          last_compacted_seq: to_seq,
          metadata: Map.put(snapshot.metadata || %{}, :skipped_parts_count, length(all_messages) - length(filtered_messages))
      }

      {:ok, new_snapshot, from_seq, to_seq}
    else
      # Not enough messages yet, but update metadata
      new_snapshot = %{
        snapshot
        | metadata: Map.put(snapshot.metadata || %{}, :skipped_parts_count, length(all_messages) - length(filtered_messages))
      }

      {:noop, new_snapshot}
    end
  end
end
