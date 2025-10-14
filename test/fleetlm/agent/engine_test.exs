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
end
