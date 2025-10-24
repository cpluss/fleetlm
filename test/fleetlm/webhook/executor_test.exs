defmodule Fleetlm.Webhook.ExecutorTest do
  use Fleetlm.TestCase

  alias Fleetlm.Agent
  alias Fleetlm.Runtime
  alias Fleetlm.Storage.AgentCache
  alias Fleetlm.Webhook.Executor

  defmodule StubClient do
    def call_agent_webhook(agent, payload, handler) do
      send(Process.get(:test_pid), {:payload, payload, agent.id})

      acc = %{}

      {:ok, acc} =
        handler.({:chunk, %{"type" => "text-delta", "id" => "delta", "delta" => "hey"}}, acc)

      message = %{
        "id" => "agent-msg",
        "role" => "assistant",
        "parts" => [%{"type" => "text", "text" => "hi", "state" => "done"}],
        "metadata" => %{}
      }

      {:ok, _acc} = handler.({:finalize, message, %{termination: :finish}}, acc)

      {:ok, 1}
    end

    def call_compaction_webhook(_url, payload) do
      send(Process.get(:test_pid), {:compaction_payload, payload})
      {:ok, %{summary: "ok"}}
    end
  end

  setup do
    Application.put_env(:fleetlm, :webhook_client, StubClient)
    Process.put(:test_pid, self())

    on_exit(fn ->
      Application.delete_env(:fleetlm, :webhook_client)
      Process.delete(:test_pid)
      AgentCache.clear_all()
    end)

    AgentCache.clear_all()

    :ok
  end

  test "catch_up posts payload and persists agent response" do
    agent_id = "agent:test"

    {:ok, _agent} =
      Agent.create(%{
        id: agent_id,
        name: "Test Agent",
        origin_url: "https://api.example.com",
        webhook_path: "/webhook",
        status: "enabled",
        context_strategy: "last_n",
        context_strategy_config: %{"limit" => 50},
        timeout_ms: 5_000
      })

    AgentCache.clear_all()

    session = create_test_session("user-1", agent_id)

    {:ok, seq} =
      Runtime.append_message(
        session.id,
        session.user_id,
        agent_id,
        "text",
        %{"text" => "hello"},
        %{}
      )

    params = %{
      session_id: session.id,
      agent_id: agent_id,
      user_id: session.user_id,
      from_seq: 0,
      to_seq: seq,
      user_message_sent_at: System.monotonic_time(:millisecond),
      context_snapshot: nil
    }

    assert {:ok, %{last_sent_seq: ^seq, message_count: 1, snapshot: snapshot}} =
             Executor.catch_up(params)

    assert_receive {:payload, payload, ^agent_id}
    assert payload.context.strategy == "last_n"
    assert [%{seq: ^seq} | _] = payload.messages
    assert snapshot.strategy_id == "last_n"

    {:ok, messages} = Runtime.get_messages(session.id, 0, 10)
    assert Enum.any?(messages, &(&1.sender_id == agent_id && &1.kind == "assistant"))
  end

  test "compact delegates to webhook client" do
    session_id = "session-1"

    params = %{
      session_id: session_id,
      webhook_url: "https://example.com/compact",
      payload: %{range_start: 1, range_end: 10}
    }

    assert {:ok, %{summary: "ok"}} = Executor.compact(params)
    assert_receive {:compaction_payload, %{range_start: 1, range_end: 10}}
  end
end
