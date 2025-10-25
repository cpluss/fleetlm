defmodule Fastpaca.Context.LLMContext do
  @moduledoc """
  LLM-facing window (context window) of a context. Contains the compacted view
  of messages that will be sent to the LLM, along with token count tracking.

  Messages are stored in reverse chronological order (newest first) for fast tail access.
  """

  alias __MODULE__, as: LLMContext

  @enforce_keys [:messages, :token_count]
  defstruct messages: [], token_count: 0, metadata: %{}

  @type ui_message :: %{
          role: String.t(),
          parts: [map()],
          seq: non_neg_integer(),
          inserted_at: NaiveDateTime.t(),
          token_count: non_neg_integer(),
          metadata: map()
        }

  @type t :: %LLMContext{
          messages: [ui_message()],
          token_count: non_neg_integer(),
          metadata: map()
        }

  @spec new() :: t()
  def new, do: %LLMContext{messages: [], token_count: 0, metadata: %{}}

  @spec append(t(), [ui_message()]) :: t()
  def append(%LLMContext{} = llm_context, messages) do
    # Prepend reversed messages (newest first)
    new_messages = Enum.reverse(messages) ++ llm_context.messages

    %LLMContext{
      llm_context
      | messages: new_messages,
        token_count: llm_context.token_count + sum_tokens(messages)
    }
  end

  @spec compact(t(), [ui_message()]) :: t()
  def compact(%LLMContext{} = llm_context, messages) do
    # Messages come in chronological order, reverse for storage
    %LLMContext{
      llm_context
      | messages: Enum.reverse(messages),
        token_count: sum_tokens(messages)
    }
  end

  @spec to_list(t()) :: [ui_message()]
  def to_list(%LLMContext{messages: messages}), do: Enum.reverse(messages)

  defp sum_tokens(messages) do
    Enum.reduce(messages, 0, fn message, acc -> acc + message.token_count end)
  end
end
