defmodule Fastpaca.Context.Policies.LastN do
  @moduledoc """
  Keeps only the last N messages in the LLM context while preserving the full
  append-only log.
  """

  @behaviour Fastpaca.Context.Policy

  alias Fastpaca.Context.LLMContext

  @default_limit 200

  @impl true
  def apply(%LLMContext{messages: messages} = llm_context, config) do
    limit = config[:limit] || @default_limit
    kept = take_last(messages, limit)

    new_llm_context = %LLMContext{
      llm_context
      | messages: kept,
        token_count: sum_tokens(kept),
        metadata: %{strategy: "last_n", limit: limit}
    }

    {:ok, new_llm_context, :compact}
  end

  defp take_last(list, limit) do
    count = length(list)

    if count <= limit do
      list
    else
      Enum.slice(list, count - limit, limit)
    end
  end

  defp sum_tokens(messages) do
    Enum.reduce(messages, 0, fn message, acc -> acc + message.token_count end)
  end
end
