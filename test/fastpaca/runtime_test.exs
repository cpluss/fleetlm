defmodule Fastpaca.RuntimeTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Fastpaca.Runtime
  alias Fastpaca.Runtime.RaftManager
  alias Fastpaca.Context.Config

  setup do
    # Clean up any existing Raft groups
    for group_id <- 0..(RaftManager.num_groups() - 1) do
      server_id = RaftManager.server_id(group_id)
      full_server_id = {server_id, Node.self()}

      case Process.whereis(server_id) do
        nil ->
          # Even if process is dead, Ra might still have it registered
          # Force delete from Ra's internal registry
          try do
            :ra.force_delete_server(:default, full_server_id)
          catch
            _, _ -> :ok
          end

        pid ->
          # Stop the server gracefully first
          ref = Process.monitor(pid)
          Process.exit(pid, :kill)

          receive do
            {:DOWN, ^ref, :process, ^pid, _} -> :ok
          after
            1000 -> :ok
          end

          # Now force delete from Ra's registry
          try do
            :ra.force_delete_server(:default, full_server_id)
          catch
            _, _ -> :ok
          end
      end
    end

    # Remove residual Raft data on disk
    Fastpaca.Runtime.TestHelper.reset()

    # Give Ra time to fully clean up
    Process.sleep(100)

    :ok
  end

  describe "Runtime.upsert_context/3" do
    test "creates a new context via Raft" do
      config = %Config{
        token_budget: 100_000,
        trigger_ratio: 0.7,
        policy: %{strategy: :last_n, config: %{limit: 100}}
      }

      {:ok, result} = Runtime.upsert_context("ctx-1", config)

      assert result.id == "ctx-1"
      assert result.version == 0
      assert result.last_seq == 0
      assert result.status == :active
    end

    test "updates an existing context" do
      config1 = %Config{
        token_budget: 50_000,
        trigger_ratio: 0.7,
        policy: %{strategy: :last_n, config: %{limit: 50}}
      }

      {:ok, _result} = Runtime.upsert_context("ctx-2", config1)

      config2 = %Config{
        token_budget: 100_000,
        trigger_ratio: 0.8,
        policy: %{strategy: :last_n, config: %{limit: 100}}
      }

      {:ok, updated} = Runtime.upsert_context("ctx-2", config2)

      assert updated.token_budget == 100_000
      assert updated.trigger_ratio == 0.8
    end
  end

  describe "Runtime.append_messages/3" do
    test "appends messages to a context" do
      config = %Config{
        token_budget: 100_000,
        trigger_ratio: 0.7,
        policy: %{strategy: :last_n, config: %{limit: 100}}
      }

      {:ok, _ctx} = Runtime.upsert_context("ctx-1", config)

      inbound = [
        {"user", [%{type: "text", text: "Hello"}], %{}, 10},
        {"assistant", [%{type: "text", text: "Hi"}], %{}, 10}
      ]

      {:ok, results} = Runtime.append_messages("ctx-1", inbound)

      assert length(results) == 2
      assert hd(results).seq == 1
      assert hd(results).context_id == "ctx-1"
    end

    test "sequences are monotonically increasing" do
      config = %Config{
        token_budget: 100_000,
        trigger_ratio: 0.7,
        policy: %{strategy: :last_n, config: %{limit: 100}}
      }

      {:ok, _ctx} = Runtime.upsert_context("ctx-3", config)

      {:ok, results1} = Runtime.append_messages("ctx-3", [{"user", [%{type: "text"}], %{}, 10}])
      {:ok, results2} = Runtime.append_messages("ctx-3", [{"user", [%{type: "text"}], %{}, 10}])

      assert hd(results1).seq == 1
      assert hd(results2).seq == 2
    end
  end

  describe "Runtime.get_context/1" do
    test "retrieves full context from Raft" do
      config = %Config{
        token_budget: 100_000,
        trigger_ratio: 0.7,
        policy: %{strategy: :last_n, config: %{limit: 100}}
      }

      {:ok, _ctx} = Runtime.upsert_context("ctx-4", config)
      {:ok, _} = Runtime.append_messages("ctx-4", [{"user", [%{type: "text"}], %{}, 10}])

      {:ok, context} = Runtime.get_context("ctx-4")

      assert context.id == "ctx-4"
      assert context.last_seq == 1
      assert context.version > 0
    end

    test "returns error for non-existent context" do
      # Returns :noproc when Raft group hasn't been started
      assert {:error, _} = Runtime.get_context("nonexistent")
    end
  end

  describe "Runtime.get_context_window/1" do
    test "returns LLM-facing context window" do
      config = %Config{
        token_budget: 100_000,
        trigger_ratio: 0.7,
        policy: %{strategy: :last_n, config: %{limit: 100}}
      }

      {:ok, _ctx} = Runtime.upsert_context("ctx-5", config)

      inbound = [
        {"user", [%{type: "text"}], %{}, 10},
        {"assistant", [%{type: "text"}], %{}, 10}
      ]

      {:ok, _} = Runtime.append_messages("ctx-5", inbound)

      {:ok, window} = Runtime.get_context_window("ctx-5")

      assert length(window.messages) == 2
      assert window.token_count == 20
      assert window.needs_compaction == false
      assert is_integer(window.version)
    end
  end

  # Helper to generate truly unique context IDs that won't collide with existing tests
  defp unique_ctx_id(prefix) do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}-#{:rand.uniform(999_999_999)}"
  end

  describe "Runtime.get_messages_tail/3" do
    test "retrieves last N messages with default offset" do
      config = %Config{
        token_budget: 100_000,
        trigger_ratio: 0.7,
        policy: %{strategy: :last_n, config: %{limit: 100}}
      }

      ctx_id = unique_ctx_id("tail-last-n")
      {:ok, _ctx} = Runtime.upsert_context(ctx_id, config)

      # Add 10 messages
      inbound = for _ <- 1..10, do: {"user", [%{type: "text"}], %{}, 10}
      {:ok, _} = Runtime.append_messages(ctx_id, inbound)

      # Get last 3 messages
      {:ok, messages} = Runtime.get_messages_tail(ctx_id, 0, 3)

      assert length(messages) == 3
      assert Enum.map(messages, & &1.seq) == [8, 9, 10]
    end

    test "retrieves messages with offset from tail" do
      config = %Config{
        token_budget: 100_000,
        trigger_ratio: 0.7,
        policy: %{strategy: :last_n, config: %{limit: 100}}
      }

      ctx_id = unique_ctx_id("tail-offset")
      {:ok, _ctx} = Runtime.upsert_context(ctx_id, config)

      inbound = for _ <- 1..10, do: {"user", [%{type: "text"}], %{}, 10}
      {:ok, _} = Runtime.append_messages(ctx_id, inbound)

      # Skip last 3, get next 4 (should be seq 4, 5, 6, 7)
      {:ok, messages} = Runtime.get_messages_tail(ctx_id, 3, 4)

      assert length(messages) == 4
      assert Enum.map(messages, & &1.seq) == [4, 5, 6, 7]
    end

    test "pagination through entire message history" do
      config = %Config{
        token_budget: 100_000,
        trigger_ratio: 0.7,
        policy: %{strategy: :last_n, config: %{limit: 100}}
      }

      ctx_id = unique_ctx_id("tail-pages")
      {:ok, _ctx} = Runtime.upsert_context(ctx_id, config)

      inbound = for _ <- 1..10, do: {"user", [%{type: "text"}], %{}, 10}
      {:ok, _} = Runtime.append_messages(ctx_id, inbound)

      # Page 1: last 3 messages
      {:ok, page1} = Runtime.get_messages_tail(ctx_id, 0, 3)
      assert Enum.map(page1, & &1.seq) == [8, 9, 10]

      # Page 2: next 3 messages
      {:ok, page2} = Runtime.get_messages_tail(ctx_id, 3, 3)
      assert Enum.map(page2, & &1.seq) == [5, 6, 7]

      # Page 3: next 3 messages
      {:ok, page3} = Runtime.get_messages_tail(ctx_id, 6, 3)
      assert Enum.map(page3, & &1.seq) == [2, 3, 4]

      # Page 4: remaining messages
      {:ok, page4} = Runtime.get_messages_tail(ctx_id, 9, 3)
      assert Enum.map(page4, & &1.seq) == [1]
    end

    test "returns empty list when offset exceeds count" do
      config = %Config{
        token_budget: 100_000,
        trigger_ratio: 0.7,
        policy: %{strategy: :last_n, config: %{limit: 100}}
      }

      ctx_id = unique_ctx_id("tail-empty")
      {:ok, _ctx} = Runtime.upsert_context(ctx_id, config)

      inbound = for _ <- 1..5, do: {"user", [%{type: "text"}], %{}, 10}
      {:ok, _} = Runtime.append_messages(ctx_id, inbound)

      {:ok, messages} = Runtime.get_messages_tail(ctx_id, 100, 10)

      assert messages == []
    end

    test "uses default parameters when not specified" do
      config = %Config{
        token_budget: 100_000,
        trigger_ratio: 0.7,
        policy: %{strategy: :last_n, config: %{limit: 100}}
      }

      ctx_id = unique_ctx_id("tail-defaults")
      {:ok, _ctx} = Runtime.upsert_context(ctx_id, config)

      inbound = for _ <- 1..10, do: {"user", [%{type: "text"}], %{}, 10}
      {:ok, _} = Runtime.append_messages(ctx_id, inbound)

      # Should use defaults: offset=0, limit=100
      {:ok, messages} = Runtime.get_messages_tail(ctx_id)

      assert length(messages) == 10
      assert Enum.map(messages, & &1.seq) == Enum.to_list(1..10)
    end
  end

  describe "Runtime.compact/3" do
    test "manually compacts a context" do
      config = %Config{
        token_budget: 100_000,
        trigger_ratio: 0.7,
        policy: %{strategy: :manual, config: %{}}
      }

      {:ok, _ctx} = Runtime.upsert_context("ctx-7", config)

      inbound = for _ <- 1..5, do: {"user", [%{type: "text"}], %{}, 10}
      {:ok, _} = Runtime.append_messages("ctx-7", inbound)

      replacement = [
        %{
          role: "system",
          parts: [%{type: "text", text: "Summary"}],
          seq: 999,
          inserted_at: NaiveDateTime.utc_now(),
          token_count: 5,
          metadata: %{}
        }
      ]

      {:ok, version} = Runtime.compact("ctx-7", replacement)
      assert is_integer(version)

      {:ok, window} = Runtime.get_context_window("ctx-7")
      assert length(window.messages) == 1
      assert window.token_count == 5
    end
  end

  describe "Raft failover and recovery" do
    test "recovers state after server crash and restart" do
      capture_log(fn ->
        config = %Config{
          token_budget: 100_000,
          trigger_ratio: 0.7,
          policy: %{strategy: :last_n, config: %{limit: 100}}
        }

        {:ok, _ctx} = Runtime.upsert_context("ctx-failover", config)

        {:ok, results1} =
          Runtime.append_messages("ctx-failover", [
            {"user", [%{type: "text", text: "before crash"}], %{}, 10}
          ])

        assert hd(results1).seq == 1

        # Kill the Raft group
        group_id = RaftManager.group_for_context("ctx-failover")
        server_id = RaftManager.server_id(group_id)
        pid = Process.whereis(server_id)

        ref = Process.monitor(pid)
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          2000 -> flunk("Raft process did not die")
        end

        # Restart the group (may not form cluster in test env)
        start_result = RaftManager.start_group(group_id)
        assert start_result in [:ok, {:error, :cluster_not_formed}]

        # Wait for restart
        eventually(
          fn ->
            assert Process.whereis(server_id)
          end,
          timeout: 3_000
        )

        # Append after crash
        {:ok, results2} =
          Runtime.append_messages("ctx-failover", [
            {"user", [%{type: "text", text: "after crash"}], %{}, 10}
          ])

        assert hd(results2).seq >= 2

        # Verify both messages exist
        {:ok, messages} = Runtime.get_messages_tail("ctx-failover", 0, 10)
        texts = Enum.map(messages, &(&1.parts |> hd() |> Map.get(:text)))

        assert "before crash" in texts
        assert "after crash" in texts
      end)
    end

    test "recovers with thousands of messages after crash" do
      capture_log(fn ->
        config = %Config{
          token_budget: 1_000_000,
          trigger_ratio: 0.7,
          policy: %{strategy: :last_n, config: %{limit: 5000}}
        }

        {:ok, _ctx} = Runtime.upsert_context("ctx-stress", config)

        # Append 1000 messages
        inbound = for i <- 1..1000, do: {"user", [%{type: "text", text: "msg-#{i}"}], %{}, 10}
        {:ok, results} = Runtime.append_messages("ctx-stress", inbound)
        assert length(results) == 1000
        last_seq_before = hd(Enum.reverse(results)).seq

        # Kill and restart
        group_id = RaftManager.group_for_context("ctx-stress")
        server_id = RaftManager.server_id(group_id)
        pid = Process.whereis(server_id)

        ref = Process.monitor(pid)
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          2000 -> flunk("Raft process did not die")
        end

        start_result = RaftManager.start_group(group_id)
        assert start_result in [:ok, {:error, :cluster_not_formed}]

        eventually(
          fn ->
            assert Process.whereis(server_id)
          end,
          timeout: 3_000
        )

        # Verify all messages still exist
        {:ok, context} = Runtime.get_context("ctx-stress")
        assert context.last_seq == last_seq_before

        {:ok, window} = Runtime.get_context_window("ctx-stress")
        # Should have messages in window
        assert length(window.messages) > 0
      end)
    end
  end

  describe "Compaction behavior" do
    test "compaction triggers automatically at threshold" do
      config = %Config{
        token_budget: 100,
        trigger_ratio: 0.7,
        policy: %{strategy: :last_n, config: %{limit: 2}}
      }

      {:ok, _ctx} = Runtime.upsert_context("ctx-compact", config)

      # Append messages that exceed 70 tokens
      inbound = [
        {"user", [%{type: "text"}], %{}, 30},
        {"assistant", [%{type: "text"}], %{}, 30},
        {"user", [%{type: "text"}], %{}, 30}
      ]

      {:ok, _results} = Runtime.append_messages("ctx-compact", inbound)

      # Check window was compacted
      {:ok, window} = Runtime.get_context_window("ctx-compact")
      assert length(window.messages) == 2
      assert window.token_count == 60

      # Full message log should still have all 3 messages
      {:ok, messages} = Runtime.get_messages_tail("ctx-compact", 0, 100)
      assert length(messages) == 3
    end

    test "skip_parts policy filters tool messages" do
      config = %Config{
        token_budget: 100,
        trigger_ratio: 0.5,
        policy: %{strategy: :skip_parts, config: %{skip_kinds: [:tool], limit: 10}}
      }

      {:ok, _ctx} = Runtime.upsert_context("ctx-skip", config)

      inbound = [
        {"user", [%{type: "text"}], %{}, 20},
        {"assistant", [%{type: "tool_call"}], %{}, 20},
        {"tool", [%{type: "tool_result"}], %{}, 20},
        {"assistant", [%{type: "text"}], %{}, 20}
      ]

      {:ok, _results} = Runtime.append_messages("ctx-skip", inbound)

      {:ok, window} = Runtime.get_context_window("ctx-skip")
      roles = Enum.map(window.messages, & &1.role)

      # Tool messages should be filtered out
      refute "tool" in roles
      assert "user" in roles
      assert "assistant" in roles
    end

    test "manual policy never auto-compacts" do
      config = %Config{
        token_budget: 50,
        trigger_ratio: 0.5,
        policy: %{strategy: :manual, config: %{}}
      }

      {:ok, _ctx} = Runtime.upsert_context("ctx-manual", config)

      # Exceed budget significantly
      inbound = for _ <- 1..10, do: {"user", [%{type: "text"}], %{}, 20}
      {:ok, _results} = Runtime.append_messages("ctx-manual", inbound)

      # Window should have ALL messages (no auto-compact)
      {:ok, window} = Runtime.get_context_window("ctx-manual")
      assert length(window.messages) == 10
      assert window.token_count == 200
      assert window.needs_compaction == true
    end
  end

  describe "Concurrent access" do
    test "multiple contexts can be appended concurrently" do
      config = %Config{
        token_budget: 100_000,
        trigger_ratio: 0.7,
        policy: %{strategy: :last_n, config: %{limit: 100}}
      }

      # Create 10 contexts
      for i <- 1..10 do
        {:ok, _ctx} = Runtime.upsert_context("ctx-concurrent-#{i}", config)
      end

      # Append to all concurrently
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            Runtime.append_messages("ctx-concurrent-#{i}", [
              {"user", [%{type: "text"}], %{}, 10}
            ])
          end)
        end

      results = Task.await_many(tasks, 5000)

      # All should succeed
      assert Enum.all?(results, fn
               {:ok, _} -> true
               _ -> false
             end)
    end
  end

  # Helper to wait for eventually condition
  defp eventually(fun, opts) when is_function(fun, 0) and is_list(opts) do
    timeout = Keyword.get(opts, :timeout, 1000)
    interval = Keyword.get(opts, :interval, 50)
    deadline = System.monotonic_time(:millisecond) + timeout

    do_eventually(fun, deadline, interval)
  end

  defp do_eventually(fun, deadline, interval) do
    try do
      fun.()
    rescue
      _ ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(interval)
          do_eventually(fun, deadline, interval)
        else
          fun.()
        end
    end
  end
end
