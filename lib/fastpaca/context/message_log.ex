defmodule Fastpaca.Context.MessageLog do
  @moduledoc """
  Append-only message history for a context.

  Messages are stored in reverse chronological order (newest first) for fast tail access.
  """

  alias __MODULE__, as: MessageLog

  @type inbound :: {
          Fastpaca.Context.role(),
          [Fastpaca.Context.part()],
          %{optional(atom()) => term()},
          non_neg_integer()
        }

  @type entry :: Fastpaca.Context.ui_message()

  @enforce_keys [:entries]
  defstruct entries: []

  @type t :: %MessageLog{entries: [entry()]}

  @spec new() :: t()
  def new, do: %MessageLog{entries: []}

  @spec entries(t()) :: [entry()]
  def entries(%MessageLog{entries: entries}), do: Enum.reverse(entries)

  @spec append(t(), [inbound()], non_neg_integer()) :: {t(), [entry()], non_neg_integer()}
  def append(%MessageLog{entries: entries} = log, inbound_messages, last_seq) do
    {appended, final_seq} =
      Enum.map_reduce(inbound_messages, last_seq, fn {role, parts, metadata, token_count}, seq ->
        next_seq = seq + 1

        message = %{
          role: role,
          parts: parts,
          metadata: metadata,
          token_count: token_count,
          seq: next_seq,
          inserted_at: NaiveDateTime.utc_now()
        }

        {message, next_seq}
      end)

    # Prepend reversed appended messages (newest first)
    new_entries = Enum.reverse(appended) ++ entries

    {%MessageLog{log | entries: new_entries}, appended, final_seq}
  end

  @spec tail(t(), pos_integer()) :: [entry()]
  def tail(%MessageLog{entries: entries}, limit) do
    entries
    |> Enum.take(limit)
    |> Enum.reverse()
  end

  @doc """
  Retrieves messages from the tail (newest) with an offset and limit.

  ## Parameters
    - `offset`: Number of messages to skip from the tail (0 = most recent)
    - `limit`: Maximum number of messages to return

  ## Examples
      # Get last 50 messages
      tail_with_offset(log, 0, 50)

      # Get messages 51-100 from the tail
      tail_with_offset(log, 50, 50)

  Returns messages in chronological order (oldest to newest in the result).
  """
  @spec tail_with_offset(t(), non_neg_integer(), pos_integer()) :: [entry()]
  def tail_with_offset(%MessageLog{entries: entries}, offset, limit) do
    entries
    |> Enum.drop(offset)
    |> Enum.take(limit)
    |> Enum.reverse()
  end

  @doc """
  Trim acknowledged messages while retaining a bounded tail.

  Drops all entries with `seq <= upto_seq`, but retains up to `tail_keep`
  additional entries immediately below that boundary if present. Always keeps
  entries with `seq > upto_seq`.

  Returns the updated log and the number of entries removed.
  """
  @spec trim_ack(t(), non_neg_integer(), pos_integer()) :: {t(), non_neg_integer()}
  def trim_ack(%MessageLog{entries: entries} = log, upto_seq, tail_keep)
      when is_integer(upto_seq) and upto_seq >= 0 and is_integer(tail_keep) and tail_keep > 0 do
    # entries are newest-first; split by boundary
    {newer, older_or_equal} = Enum.split_with(entries, fn %{seq: seq} -> seq > upto_seq end)

    # From the older_or_equal side (newest-first), retain up to tail_keep entries
    # immediately below the boundary
    retained_from_older = older_or_equal |> Enum.take(tail_keep)

    kept = newer ++ retained_from_older
    removed = length(entries) - length(kept)

    {%MessageLog{log | entries: kept}, max(removed, 0)}
  end
end
