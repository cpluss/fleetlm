defmodule Fastpaca.Context.MessageLog do
  @moduledoc """
  Append-only message history for a context.
  """

  @type inbound :: {
          Fastpaca.Context.role(),
          [Fastpaca.Context.part()],
          %{optional(atom()) => term()},
          non_neg_integer()
        }

  @type entry :: Fastpaca.Context.ui_message()

  @enforce_keys [:entries]
  defstruct entries: []

  @type t :: %__MODULE__{entries: [entry()]}

  @spec new() :: t()
  def new, do: %__MODULE__{entries: []}

  @spec entries(t()) :: [entry()]
  def entries(%__MODULE__{entries: entries}), do: entries

  @spec append(t(), [inbound()], non_neg_integer()) :: {t(), [entry()], non_neg_integer()}
  def append(%__MODULE__{entries: entries} = log, inbound_messages, last_seq) do
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

    {%__MODULE__{log | entries: entries ++ appended}, appended, final_seq}
  end

  @spec slice(t(), non_neg_integer(), pos_integer() | :infinity) :: [entry()]
  def slice(%__MODULE__{entries: entries}, after_seq, :infinity) do
    Enum.filter(entries, &(&1.seq > after_seq))
  end

  def slice(%__MODULE__{entries: entries}, after_seq, limit) do
    entries
    |> Enum.filter(&(&1.seq > after_seq))
    |> Enum.take(limit)
  end
end
