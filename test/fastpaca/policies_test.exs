defmodule Fastpaca.PoliciesTest do
  use ExUnit.Case, async: true

  alias Fastpaca.Context.LLMContext
  alias Fastpaca.Context.Policies.{LastN, Manual, SkipParts}

  describe "LastN.apply/2" do
    test "keeps only the configured number of messages and recalculates tokens" do
      llm_context =
        LLMContext.new()
        |> LLMContext.append([
          build_message("user", 1, 5),
          build_message("assistant", 2, 7),
          build_message("tool", 3, 9)
        ])

      {:ok, compacted, flag} = LastN.apply(llm_context, %{limit: 2})

      assert flag == :compact
      assert length(compacted.messages) == 2
      assert compacted.token_count == 16
      assert compacted.metadata == %{strategy: "last_n", limit: 2}

      # Messages stored newest-first internally
      roles = Enum.map(compacted.messages, & &1.role)
      assert roles == ["tool", "assistant"]
    end
  end

  describe "Manual.apply/2" do
    test "passes the context through unchanged" do
      llm_context =
        LLMContext.new()
        |> LLMContext.append([build_message("user", 1, 5)])

      {:ok, same_context, flag} = Manual.apply(llm_context, %{})

      assert flag == :noop
      assert same_context == llm_context
    end
  end

  describe "SkipParts.apply/2" do
    test "drops messages with matching part prefixes then delegates to LastN" do
      llm_context =
        LLMContext.new()
        |> LLMContext.append([
          build_message("user", 1, 5, [%{type: "text"}]),
          build_message("assistant", 2, 6, [%{type: "tool_call"}]),
          build_message("tool", 3, 7, [%{type: "tool_result"}]),
          build_message("assistant", 4, 8, [%{type: "text"}])
        ])

      {:ok, compacted, flag} = SkipParts.apply(llm_context, %{limit: 10})

      assert flag == :compact
      assert Enum.map(compacted.messages, & &1.role) == ["assistant", "user"]
      assert compacted.token_count == 13
      assert compacted.metadata[:strategy] == "last_n"
      assert compacted.metadata[:limit] == 10
      assert compacted.metadata[:skipped_parts] == 2
    end
  end

  defp build_message(role, seq, tokens, parts \\ [%{type: "text"}]) do
    %{
      role: role,
      parts: parts,
      seq: seq,
      inserted_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second),
      token_count: tokens,
      metadata: %{}
    }
  end
end
