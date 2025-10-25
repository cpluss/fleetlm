defmodule Fastpaca.Context.Policies.Manual do
  @moduledoc """
  Leaves the LLM context untouched; useful when developers manage compaction
  themselves.
  """

  @behaviour Fastpaca.Context.Policy

  alias Fastpaca.Context.LLMContext

  @impl true
  def apply(%LLMContext{} = llm_context, _config) do
    {:ok, llm_context, :noop}
  end
end
