defmodule Fleetlm.Runtime.RaftManagerTest do
  use Fleetlm.TestCase

  alias Fleetlm.Runtime.RaftManager

  describe "group_for_session/1" do
    test "maps session to group via phash2" do
      session_id = "test_session_123"

      group = RaftManager.group_for_session(session_id)

      # Should be deterministic
      assert group == :erlang.phash2(session_id, 256)
      assert group >= 0
      assert group < 256

      # Same session should always map to same group
      assert group == RaftManager.group_for_session(session_id)
    end

    test "distributes sessions across groups" do
      # Generate 1000 session IDs and verify distribution
      groups =
        for i <- 1..1000 do
          session_id = "session_#{i}"
          RaftManager.group_for_session(session_id)
        end

      # Should use multiple groups (not all map to same group)
      unique_groups = Enum.uniq(groups) |> length()
      assert unique_groups > 50
    end
  end

  describe "lane_for_session/1" do
    test "maps session to lane via phash2" do
      session_id = "test_session_123"

      lane = RaftManager.lane_for_session(session_id)

      # Should be deterministic
      assert lane == :erlang.phash2(session_id, 16)
      assert lane >= 0
      assert lane < 16

      # Same session should always map to same lane
      assert lane == RaftManager.lane_for_session(session_id)
    end
  end

  describe "replicas_for_group/1" do
    test "returns deterministic replica placement" do
      group_id = 42

      replicas = RaftManager.replicas_for_group(group_id)

      # Should return up to 3 replicas (in single-node test, just 1)
      assert length(replicas) >= 1
      assert length(replicas) <= 3

      # Should be deterministic
      assert replicas == RaftManager.replicas_for_group(group_id)
    end

    test "different groups may have different replicas" do
      # In single-node test, all groups will have same replica (local node)
      # In multi-node cluster, different groups would have different replicas
      # This test just validates the function doesn't crash

      replicas1 = RaftManager.replicas_for_group(0)
      replicas2 = RaftManager.replicas_for_group(100)

      assert length(replicas1) >= 1
      assert length(replicas2) >= 1
    end
  end

  describe "server_id/1" do
    test "returns consistent server ID for group" do
      group_id = 42

      server_id = RaftManager.server_id(group_id)

      # Server ID is an atom (for Ra process registration)
      assert server_id == :raft_group_42
    end
  end
end
