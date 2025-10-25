defmodule Fastpaca.Context.LLMContext do
  @moduledoc """
  LLM-facing window (context window) of a context. Contains the compacted view
  of messages that will be sent to the LLM, along with token count tracking.
  """

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

  @type t :: %__MODULE__{
          messages: [ui_message()],
          token_count: non_neg_integer(),
          metadata: map()
        }

  @spec new() :: t()
  def new, do: %__MODULE__{messages: [], token_count: 0, metadata: %{}}

  @spec append(t(), [ui_message()]) :: t()
  def append(%__MODULE__{} = llm_context, messages) do
    %__MODULE__{
      llm_context
      | messages: llm_context.messages ++ messages,
        token_count: llm_context.token_count + sum_tokens(messages)
    }
  end

  @spec compact(t(), [ui_message()]) :: t()
  def compact(%__MODULE__{} = llm_context, messages) do
    %__MODULE__{
      llm_context
      | messages: messages,
        token_count: sum_tokens(messages)
    }
  end

  defp sum_tokens(messages) do
    Enum.reduce(messages, 0, fn message, acc -> acc + message.token_count end)
  end
end
