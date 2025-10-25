defmodule Fastpaca.Context.Strategies.SkipParts do
  @moduledoc """
  Drops messages containing certain part types before delegating to the LastN
  strategy.
  """

  @behaviour Fastpaca.Context.Policy

  alias Fastpaca.Context.LLMContext

  @default_skip_kinds [:tool]

  @impl true
  def apply(messages, %LLMContext{} = existing, config) do
    skip_kinds = config[:skip_kinds] || @default_skip_kinds
    limit = config[:limit]

    filtered =
      Enum.filter(messages, fn message ->
        Enum.all?(message.parts, fn %{type: type} ->
          Enum.all?(skip_kinds, fn prefix -> not String.starts_with?(type, to_string(prefix)) end)
        end)
      end)

    strategy_config = %{limit: limit}

    case Fastpaca.Context.Strategies.LastN.apply(filtered, existing, strategy_config) do
      {:ok, %LLMContext{} = llm_context, flag} ->
        skipped = length(messages) - length(filtered)
        metadata = Map.put(llm_context.metadata || %{}, :skipped_parts, skipped)
        {:ok, %{llm_context | metadata: metadata}, flag}

      other ->
        other
    end
  end
end
