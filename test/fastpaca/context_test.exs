defmodule Fastpaca.ContextTest do
  use ExUnit.Case, async: true

  alias Fastpaca.Context
  alias Fastpaca.Context.{Config, LLMContext, MessageLog}

  describe "Context.new/3" do
    test "creates a new context with default values" do
      config = %Config{
        token_budget: 100_000,
        trigger_ratio: 0.7,
        policy: %{strategy: :last_n, config: %{limit: 100}}
      }

      context = Context.new("ctx-1", config)

      assert context.id == "ctx-1"
      assert context.config == config
      assert context.status == :active
      assert context.last_seq == 0
      assert context.version == 0
      assert MessageLog.entries(context.message_log) == []
      assert LLMContext.to_list(context.llm_context) == []
    end

    test "creates with custom status and metadata" do
      config = %Config{
        token_budget: 50_000,
        trigger_ratio: 0.8,
        policy: %{strategy: :manual, config: %{}}
      }

      context = Context.new("ctx-2", config, status: :tombstoned, metadata: %{foo: "bar"})

      assert context.status == :tombstoned
      assert context.metadata == %{foo: "bar"}
    end
  end

  describe "Context.append/2" do
    test "appends messages and increments sequence" do
      config = %Config{
        token_budget: 100_000,
        trigger_ratio: 0.7,
        policy: %{strategy: :last_n, config: %{limit: 100}}
      }

      context = Context.new("ctx-1", config)

      inbound = [
        {"user", [%{type: "text", text: "Hello"}], %{}, 10},
        {"assistant", [%{type: "text", text: "Hi there"}], %{}, 15}
      ]

      {new_context, appended, flag} = Context.append(context, inbound)

      assert new_context.last_seq == 2
      assert new_context.version == 1
      assert length(appended) == 2
      assert flag == :noop

      [msg1, msg2] = appended
      assert msg1.seq == 1
      assert msg1.role == "user"
      assert msg1.token_count == 10

      assert msg2.seq == 2
      assert msg2.role == "assistant"
      assert msg2.token_count == 15
    end

    test "triggers compaction when exceeding budget * trigger_ratio" do
      config = %Config{
        token_budget: 100,
        trigger_ratio: 0.7,
        policy: %{strategy: :last_n, config: %{limit: 2}}
      }

      context = Context.new("ctx-1", config)

      # Append messages that exceed 70 tokens
      inbound = [
        {"user", [%{type: "text"}], %{}, 30},
        {"assistant", [%{type: "text"}], %{}, 30},
        {"user", [%{type: "text"}], %{}, 30}
      ]

      {new_context, _appended, flag} = Context.append(context, inbound)

      assert flag == :compact
      assert new_context.llm_context.token_count <= 100
      # last_n policy with limit 2 should keep only last 2 messages
      assert length(LLMContext.to_list(new_context.llm_context)) == 2
    end

    test "messages appear in both message_log and llm_context before compaction" do
      config = %Config{
        token_budget: 100_000,
        trigger_ratio: 0.7,
        policy: %{strategy: :last_n, config: %{limit: 100}}
      }

      context = Context.new("ctx-1", config)
      inbound = [{"user", [%{type: "text"}], %{}, 10}]

      {new_context, _appended, _flag} = Context.append(context, inbound)

      log_messages = MessageLog.entries(new_context.message_log)
      llm_messages = LLMContext.to_list(new_context.llm_context)

      assert length(log_messages) == 1
      assert length(llm_messages) == 1
      assert hd(log_messages).seq == hd(llm_messages).seq
    end
  end

  describe "Context.compact/2" do
    test "manually compacts llm_context with replacement messages" do
      config = %Config{
        token_budget: 100_000,
        trigger_ratio: 0.7,
        policy: %{strategy: :manual, config: %{}}
      }

      context = Context.new("ctx-1", config)

      # Append some messages first
      inbound = [
        {"user", [%{type: "text"}], %{}, 10},
        {"assistant", [%{type: "text"}], %{}, 10},
        {"user", [%{type: "text"}], %{}, 10}
      ]

      {context, _appended, _flag} = Context.append(context, inbound)

      # Manually compact with a summary
      replacement = [
        %{
          role: "system",
          parts: [%{type: "text", text: "Summary of previous messages"}],
          seq: 999,
          inserted_at: NaiveDateTime.utc_now(),
          token_count: 5,
          metadata: %{}
        }
      ]

      {new_context, _llm_context} = Context.compact(context, replacement)

      assert new_context.version == context.version + 1
      assert length(LLMContext.to_list(new_context.llm_context)) == 1
      assert new_context.llm_context.token_count == 5

      # MessageLog should still have all original messages
      assert length(MessageLog.entries(new_context.message_log)) == 3
    end
  end

  describe "Context.messages_after/3" do
    test "returns messages after a given sequence number" do
      config = %Config{
        token_budget: 100_000,
        trigger_ratio: 0.7,
        policy: %{strategy: :last_n, config: %{limit: 100}}
      }

      context = Context.new("ctx-1", config)

      inbound = [
        {"user", [%{type: "text"}], %{}, 10},
        {"assistant", [%{type: "text"}], %{}, 10},
        {"user", [%{type: "text"}], %{}, 10}
      ]

      {context, _appended, _flag} = Context.append(context, inbound)

      messages = Context.messages_after(context, 1, :infinity)

      assert length(messages) == 2
      assert Enum.all?(messages, &(&1.seq > 1))
    end

    test "respects limit parameter" do
      config = %Config{
        token_budget: 100_000,
        trigger_ratio: 0.7,
        policy: %{strategy: :last_n, config: %{limit: 100}}
      }

      context = Context.new("ctx-1", config)

      inbound = for _i <- 1..10, do: {"user", [%{type: "text"}], %{}, 10}
      {context, _appended, _flag} = Context.append(context, inbound)

      messages = Context.messages_after(context, 0, 5)

      assert length(messages) == 5
    end
  end

  describe "Context.needs_compaction?/1" do
    test "returns true when token count exceeds budget * trigger_ratio" do
      config = %Config{
        token_budget: 100,
        trigger_ratio: 0.7,
        policy: %{strategy: :last_n, config: %{}}
      }

      context = Context.new("ctx-1", config)
      inbound = [{"user", [%{type: "text"}], %{}, 80}]

      {context, _appended, _flag} = Context.append(context, inbound)

      assert Context.needs_compaction?(context) == true
    end

    test "returns false when below threshold" do
      config = %Config{
        token_budget: 100,
        trigger_ratio: 0.7,
        policy: %{strategy: :last_n, config: %{}}
      }

      context = Context.new("ctx-1", config)
      inbound = [{"user", [%{type: "text"}], %{}, 50}]

      {context, _appended, _flag} = Context.append(context, inbound)

      assert Context.needs_compaction?(context) == false
    end
  end

  describe "Context.tombstone/1" do
    test "marks context as tombstoned" do
      config = %Config{
        token_budget: 100_000,
        trigger_ratio: 0.7,
        policy: %{strategy: :last_n, config: %{}}
      }

      context = Context.new("ctx-1", config)
      tombstoned = Context.tombstone(context)

      assert tombstoned.status == :tombstoned
      assert NaiveDateTime.compare(tombstoned.updated_at, context.updated_at) == :gt
    end
  end
end
