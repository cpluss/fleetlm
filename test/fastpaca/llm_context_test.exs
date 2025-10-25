defmodule Fastpaca.LLMContextTest do
  use ExUnit.Case, async: true

  alias Fastpaca.Context.LLMContext

  describe "new/0" do
    test "returns an empty context" do
      context = LLMContext.new()
      assert context.messages == []
      assert context.token_count == 0
      assert context.metadata == %{}
    end
  end

  describe "append/2 and to_list/1" do
    test "prepends messages and accumulates token counts" do
      base = LLMContext.new()

      messages =
        for seq <- 1..3 do
          %{
            role: "user",
            parts: [%{type: "text"}],
            seq: seq,
            inserted_at: timestamp(seq),
            token_count: seq * 10,
            metadata: %{}
          }
        end

      context = LLMContext.append(base, messages)

      assert Enum.map(context.messages, & &1.seq) == [3, 2, 1]
      assert context.token_count == 60
      assert Enum.map(LLMContext.to_list(context), & &1.seq) == [1, 2, 3]
    end
  end

  describe "compact/2" do
    test "replaces the window with the provided messages" do
      initial =
        LLMContext.new()
        |> LLMContext.append([
          build_message("user", 1, 5),
          build_message("assistant", 2, 7)
        ])

      replacement = [
        build_message("system", 10, 3),
        build_message("assistant", 11, 4)
      ]

      compacted = LLMContext.compact(initial, replacement)

      assert Enum.map(compacted.messages, & &1.seq) == [11, 10]
      assert compacted.token_count == 7
      assert Enum.map(LLMContext.to_list(compacted), & &1.seq) == [10, 11]
    end
  end

  defp build_message(role, seq, tokens) do
    %{
      role: role,
      parts: [%{type: "text"}],
      seq: seq,
      inserted_at: timestamp(seq),
      token_count: tokens,
      metadata: %{}
    }
  end

  defp timestamp(offset) do
    NaiveDateTime.utc_now()
    |> NaiveDateTime.add(offset)
    |> NaiveDateTime.truncate(:second)
  end
end
