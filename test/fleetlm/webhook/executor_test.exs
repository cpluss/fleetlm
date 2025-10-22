defmodule Fleetlm.Webhook.ExecutorTest do
  use Fleetlm.TestCase

  alias Fleetlm.Agent
  alias Fleetlm.Webhook.Executor
  alias Fleetlm.Runtime
  alias Fleetlm.Storage.AgentCache

  defmodule FakeClient do
    def call_agent_webhook(_agent, payload, handler) do
      test_pid =
        Process.get(:fake_client_test_pid) ||
          raise "fake client not configured"

      call = Process.get(:fake_client_call, 0) + 1
      Process.put(:fake_client_call, call)

      send(test_pid, {:iteration, call, payload})

      receive do
        {:continue, ^call} -> :ok
      after
        1_000 ->
          raise "test did not advance fake webhook iteration #{call}"
      end

      acc = %{ttft_emitted: false}

      {:ok, acc} =
        handler.(
          {:chunk, %{"type" => "text-delta", "id" => "delta-#{call}", "delta" => "chunk"}},
          acc
        )

      message = %{
        "id" => "agent-msg-#{call}",
        "role" => "assistant",
        "parts" => [
          %{"type" => "text", "text" => "response #{call}", "state" => "done"}
        ],
        "metadata" => %{}
      }

      {:ok, _acc} = handler.({:finalize, message, %{termination: :finish}}, acc)

      {:ok, 1}
    end

    def call_compaction_webhook(_url, _payload) do
      raise "unexpected compaction webhook call in test"
    end
  end

  setup do
    Application.put_env(:fleetlm, :webhook_client, FakeClient)

    on_exit(fn ->
      Application.delete_env(:fleetlm, :webhook_client)
      AgentCache.clear_all()
    end)

    AgentCache.clear_all()

    :ok
  end

  test "message executor drains target updates and processes batches sequentially" do
    agent_id = "agent:test"

    {:ok, _agent} =
      Agent.create(%{
        id: agent_id,
        name: "Test Agent",
        origin_url: "https://api.example.com/base",
        webhook_path: "/webhook",
        message_history_mode: "tail",
        message_history_limit: 50,
        timeout_ms: 5_000,
        headers: %{},
        status: "enabled"
      })

    AgentCache.clear_all()

    session = create_test_session("user-1", agent_id)

    {:ok, seq1} =
      Runtime.append_message(
        session.id,
        session.user_id,
        agent_id,
        "text",
        %{"text" => "Hello"},
        %{}
      )

    user_timestamp = System.monotonic_time(:millisecond)

    job = %{
      type: :message,
      session_id: session.id,
      payload: %{},
      context: %{
        agent_id: agent_id,
        user_id: session.user_id,
        target_seq: seq1,
        last_sent_seq: 0,
        user_message_sent_at: user_timestamp
      }
    }

    parent = self()

    task =
      Task.async(fn ->
        send(parent, {:executor_ready, self()})

        receive do
          {:proceed, test_pid} ->
            Process.put(:fake_client_test_pid, test_pid)
            Process.put(:fake_client_call, 0)
        end

        Executor.execute(job)
      end)

    executor_pid =
      receive do
        {:executor_ready, pid} ->
          :ok = Fleetlm.TestCase.allow_sandbox_access(pid)
          send(pid, {:proceed, self()})
          pid
      end

    iteration1_payload =
      receive do
        {:iteration, 1, payload} ->
          payload
      after
        1_000 -> flunk("expected first webhook iteration")
      end

    assert Enum.any?(iteration1_payload.messages, &(&1.seq == seq1))

    {:ok, seq2} =
      Runtime.append_message(
        session.id,
        session.user_id,
        agent_id,
        "text",
        %{"text" => "Need more"},
        %{}
      )

    send(executor_pid, {:update_target, seq2, System.monotonic_time(:millisecond)})
    send(executor_pid, {:continue, 1})

    iteration2_payload =
      receive do
        {:iteration, 2, payload} ->
          payload
      after
        1_000 -> flunk("expected second webhook iteration")
      end

    assert Enum.any?(iteration2_payload.messages, &(&1.seq == seq1))
    assert Enum.any?(iteration2_payload.messages, &(&1.seq == seq2))

    send(executor_pid, {:continue, 2})

    assert :ok = Task.await(task, 5_000)

    {:ok, messages} = Runtime.get_messages(session.id, 0, 10)
    agent_messages = Enum.filter(messages, &(&1.sender_id == agent_id))

    assert length(agent_messages) == 2

    conversation = Runtime.get_conversation_metadata(session.id)
    assert conversation.last_sent_seq == seq2
    assert conversation.state == :idle
  end
end
