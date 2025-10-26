defmodule Fastpaca.Tokenizer do
  @moduledoc """
  Token counting for UIMessage parts.

  This provides a minimal, dependency-free implementation as a placeholder.
  Replace with a proper model tokenizer in production. To customize, override
  this module via your own implementation if needed.
  """

  @type part :: map()

  @spec count_parts([part()]) :: non_neg_integer()
  def count_parts(parts) when is_list(parts) do
    parts
    |> Enum.reduce(0, fn part, acc -> acc + count_part(part) end)
  end

  @spec count_part(part()) :: non_neg_integer()
  defp count_part(%{"type" => "text", "text" => text}) when is_binary(text) do
    count_text(text)
  end

  defp count_part(%{"type" => _} = part) do
    count_json(part)
  end

  defp count_part(%{type: "text", text: text}) when is_binary(text) do
    count_text(text)
  end

  defp count_part(part) when is_map(part) do
    count_json(part)
  end

  # Very rough approximation: ~4 characters per token
  defp count_text(text) when is_binary(text) do
    # ceil(length/4)
    len = String.length(text)
    max(1, div(len + 3, 4))
  end

  defp count_json(map) when is_map(map) do
    len = map |> Jason.encode!() |> String.length()
    max(1, div(len + 3, 4))
  end
end
