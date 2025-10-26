defmodule Fastpaca.Context.Policies.SkipParts do
  @moduledoc """
  Drops messages containing certain part types before delegating to the LastN
  strategy.
  """

  @behaviour Fastpaca.Context.Policy

  alias Fastpaca.Context.LLMContext
  alias Fastpaca.Context.Policies.LastN

  @impl true
  def apply(%LLMContext{messages: messages} = llm_context, %{skip_kinds: skip_kinds, limit: limit})
      when is_list(skip_kinds) and is_integer(limit) and limit > 0 do
    filtered =
      Enum.filter(messages, fn message ->
        Enum.all?(message.parts, fn %{type: type} ->
          Enum.all?(skip_kinds, fn prefix -> not String.starts_with?(type, to_string(prefix)) end)
        end)
      end)

    filtered_llm_context = %LLMContext{llm_context | messages: filtered}
    strategy_config = %{limit: limit}

    {:ok, %LLMContext{} = compacted_llm_context, flag} =
      LastN.apply(filtered_llm_context, strategy_config)

    skipped = length(messages) - length(filtered)
    metadata = Map.put(compacted_llm_context.metadata, :skipped_parts, skipped)

    {:ok, %{compacted_llm_context | metadata: metadata}, flag}
  end
end
