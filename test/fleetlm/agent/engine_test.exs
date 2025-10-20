defmodule Fleetlm.Agent.EngineTest do
  use ExUnit.Case, async: false

  alias Fleetlm.Agent.Engine

  describe "retry_strategy_for_status/1" do
    test "drops on 404" do
      assert :drop == Engine.retry_strategy_for_status(404)
    end

    test "retries on 502" do
      assert :retry == Engine.retry_strategy_for_status(502)
    end

    test "drops on 500" do
      assert :drop == Engine.retry_strategy_for_status(500)
    end
  end

  describe "decide_retry/2" do
    setup do
      original = Application.get_env(:fleetlm, :agent_dispatch_retry_max_attempts)
      Application.put_env(:fleetlm, :agent_dispatch_retry_max_attempts, 3)

      on_exit(fn ->
        case original do
          nil -> Application.delete_env(:fleetlm, :agent_dispatch_retry_max_attempts)
          value -> Application.put_env(:fleetlm, :agent_dispatch_retry_max_attempts, value)
        end
      end)

      :ok
    end

    test "retries when attempts below limit" do
      assert {:retry, :backoff} == Engine.decide_retry({:http_error, 502}, 1)
    end

    test "drops when attempts reach limit" do
      assert {:drop, :max_attempts} == Engine.decide_retry({:request_failed, :timeout}, 3)
    end

    test "drops immediately on 404" do
      assert {:drop, {:http_status, 404}} == Engine.decide_retry({:http_error, 404}, 1)
    end

    test "drops when agent disabled" do
      assert {:drop, :agent_disabled} == Engine.decide_retry(:agent_disabled, 0)
    end
  end

  describe "dispatch debounce" do
    setup do
      ensure_process_started(Fleetlm.Agent.Cache)
      ensure_process_started(Fleetlm.Agent.Engine)

      :ets.delete_all_objects(:agent_dispatch_queue)
      original_disable = Application.get_env(:fleetlm, :disable_agent_webhooks)
      Application.put_env(:fleetlm, :disable_agent_webhooks, false)
      put_agent_stub("agent-test", debounce_window_ms: 500)

      on_exit(fn ->
        if :ets.whereis(:agent_dispatch_queue) != :undefined do
          :ets.delete(:agent_dispatch_queue, {"agent-test", "session-1"})
        end

        if :ets.whereis(Fleetlm.Agent.Cache) != :undefined do
          :ets.delete(Fleetlm.Agent.Cache, "agent-test")
        end

        if original_disable == nil do
          Application.delete_env(:fleetlm, :disable_agent_webhooks)
        else
          Application.put_env(:fleetlm, :disable_agent_webhooks, original_disable)
        end
      end)

      {:ok,
       %{
         engine: Process.whereis(Fleetlm.Agent.Engine),
         key: {"agent-test", "session-1"},
         agent_id: "agent-test",
         session_id: "session-1",
         user_id: "user-1"
       }}
    end

    test "enqueue retains inflight status while updating target_seq", %{
      key: key,
      session_id: session_id,
      agent_id: agent_id,
      user_id: user_id
    } do
      :ok = Engine.enqueue(session_id, agent_id, user_id, 1)
      :ets.update_element(:agent_dispatch_queue, key, [{9, :inflight}])

      :ok = Engine.enqueue(session_id, agent_id, user_id, 2)

      [
        {^key, ^user_id, last_sent, target_seq, _due_at, _first_seq, _enqueued_at, attempts,
         status}
      ] = :ets.lookup(:agent_dispatch_queue, key)

      assert last_sent == 0
      assert target_seq == 2
      assert attempts == 0
      assert status == :inflight
    end

    test "complete_dispatch keeps pending work queued", %{
      engine: engine,
      key: key,
      user_id: user_id
    } do
      now = System.monotonic_time(:millisecond)
      due_at = now + 500

      :ets.insert(:agent_dispatch_queue, {
        key,
        user_id,
        1,
        5,
        due_at,
        2,
        now,
        0,
        :inflight
      })

      info = %{
        last_sent: 3,
        duration_ms: 10,
        message_count: 3,
        started_at: now - 20,
        enqueued_at: now - 40
      }

      send(engine, {:dispatch_done, key, info})
      :sys.get_state(engine)

      [
        {^key, ^user_id, last_sent, target_seq, persisted_due_at, first_seq, enqueued_at,
         attempts, status}
      ] = :ets.lookup(:agent_dispatch_queue, key)

      assert last_sent == 3
      assert target_seq == 5
      assert persisted_due_at == due_at
      assert first_seq == 4
      assert enqueued_at == now
      assert attempts == 0
      assert status == :pending
    end

    test "complete_dispatch clears entry when no pending work remains", %{
      engine: engine,
      key: key,
      user_id: user_id
    } do
      now = System.monotonic_time(:millisecond)

      :ets.insert(:agent_dispatch_queue, {
        key,
        user_id,
        1,
        2,
        now + 500,
        2,
        now,
        0,
        :inflight
      })

      info = %{
        last_sent: 2,
        duration_ms: 8,
        message_count: 2,
        started_at: now - 10,
        enqueued_at: now - 30
      }

      send(engine, {:dispatch_done, key, info})
      :sys.get_state(engine)

      [
        {^key, ^user_id, last_sent, target_seq, due_at, first_seq, enqueued_at, attempts, status}
      ] = :ets.lookup(:agent_dispatch_queue, key)

      assert last_sent == 2
      assert target_seq == nil
      assert due_at == nil
      assert first_seq == nil
      assert enqueued_at == nil
      assert attempts == 0
      assert status == nil
    end
  end

  defp ensure_process_started(module) do
    case Process.whereis(module) do
      nil -> start_supervised!({module, []})
      pid when is_pid(pid) -> pid
    end
  end

  defp put_agent_stub(agent_id, attributes) do
    ensure_process_started(Fleetlm.Agent.Cache)

    expires_at = System.monotonic_time(:millisecond) + :timer.minutes(5)
    agent = Map.merge(%{id: agent_id}, Map.new(attributes))
    :ets.insert(Fleetlm.Agent.Cache, {agent_id, agent, expires_at})
  end
end
