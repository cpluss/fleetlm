defmodule Fastpaca.Context.Policies.LastN do
  @moduledoc """
  Keeps only the last N messages in the LLM context while preserving the full
  append-only log.
  """

  @behaviour Fastpaca.Context.Policy

  alias Fastpaca.Context.LLMContext

  @impl true
  def apply(%LLMContext{messages: messages} = llm_context, %{limit: limit})
      when is_integer(limit) and limit > 0 do
    # Messages are stored newest first, so just take the first N
    kept = Enum.take(messages, limit)

    new_llm_context = %LLMContext{
      llm_context
      | messages: kept,
        token_count: sum_tokens(kept),
        metadata: %{strategy: "last_n", limit: limit}
    }

    {:ok, new_llm_context, :compact}
  end

  defp sum_tokens(messages) do
    Enum.reduce(messages, 0, fn message, acc -> acc + message.token_count end)
  end
end
