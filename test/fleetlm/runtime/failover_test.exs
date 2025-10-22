defmodule Fleetlm.Runtime.FailoverTest do
  use Fleetlm.TestCase

  alias Fleetlm.Runtime
  alias Fleetlm.Runtime.RaftManager

  describe "raft failover" do
    test "recovers state after server crash and restart" do
      session = create_test_session("failover-user", "failover-agent")

      {:ok, seq1} =
        Runtime.append_message(
          session.id,
          session.user_id,
          session.agent_id,
          "text",
          %{"text" => "before crash"},
          %{}
        )

      assert seq1 == 1

      group_id = RaftManager.group_for_session(session.id)
      server_id = RaftManager.server_id(group_id)

      pid = Process.whereis(server_id)
      assert is_pid(pid)

      ref = Process.monitor(pid)
      Process.exit(pid, :kill)

      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2000

      start_result = RaftManager.start_group(group_id)
      assert start_result == :ok or start_result == {:error, :cluster_not_formed}

      eventually(
        fn ->
          assert Process.whereis(server_id)
        end,
        timeout: 3_000
      )

      {:ok, seq2} =
        Runtime.append_message(
          session.id,
          session.user_id,
          session.agent_id,
          "text",
          %{"text" => "after crash"},
          %{}
        )

      assert seq2 >= seq1 + 1

      {:ok, messages} = Runtime.get_messages(session.id, 0, seq2)
      assert Enum.any?(messages, &(&1.content["text"] == "before crash"))
      assert Enum.any?(messages, &(&1.content["text"] == "after crash"))
    end
  end
end
