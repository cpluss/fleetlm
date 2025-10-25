defmodule Fastpaca.Context.Policy do
  @moduledoc """
  Behaviour for compaction policies that compact the LLM context.

  Policies receive the current LLM context and return a compacted version.
  """

  alias Fastpaca.Context.LLMContext

  @callback apply(LLMContext.t(), map()) :: {:ok, LLMContext.t(), :compact | :noop}
end
