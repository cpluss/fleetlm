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

  @spec slice(t(), non_neg_integer(), pos_integer() | :infinity) :: [entry()]
  def slice(%MessageLog{entries: entries}, after_seq, :infinity) do
    entries
    |> take_while_reverse(&(&1.seq > after_seq), :infinity)
    |> Enum.reverse()
  end

  def slice(%MessageLog{entries: entries}, after_seq, limit) do
    entries
    |> take_while_reverse(&(&1.seq > after_seq), limit)
    |> Enum.reverse()
  end

  # Take while predicate is true, with limit, from a reverse-ordered list
  defp take_while_reverse(list, pred, limit) do
    take_while_reverse(list, pred, limit, [])
  end

  defp take_while_reverse([], _pred, _limit, acc), do: acc

  defp take_while_reverse(_list, _pred, 0, acc), do: acc

  defp take_while_reverse([head | tail], pred, limit, acc) do
    if pred.(head) do
      new_limit = if limit == :infinity, do: :infinity, else: limit - 1
      take_while_reverse(tail, pred, new_limit, [head | acc])
    else
      acc
    end
  end
end
