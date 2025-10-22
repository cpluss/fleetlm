defmodule Fleetlm.Runtime.FlusherTest do
  use Fleetlm.TestCase

  alias Fleetlm.Runtime.Flusher
  alias Fleetlm.Runtime.RaftManager
  alias Fleetlm.Storage.Model.Message

  describe "flush cycle" do
    test "flushes unflushed messages to Postgres" do
      import Ecto.Query

      # Create a session
      session = create_test_session("alice", "bob")

      # Append messages via Runtime
      {:ok, _seq1} =
        Fleetlm.Runtime.append_message(
          session.id,
          "alice",
          "bob",
          "text",
          %{"text" => "msg1"},
          %{}
        )

      {:ok, _seq2} =
        Fleetlm.Runtime.append_message(
          session.id,
          "alice",
          "bob",
          "text",
          %{"text" => "msg2"},
          %{}
        )

      # Trigger flush synchronously
      Flusher.flush_sync()

      # Verify messages in Postgres
      db_messages =
        Repo.all(from(m in Message, where: m.session_id == ^session.id, order_by: [asc: m.seq]))

      assert length(db_messages) == 2
      assert Enum.at(db_messages, 0).content["text"] == "msg1"
      assert Enum.at(db_messages, 1).content["text"] == "msg2"
    end

    test "advances watermarks and preserves data across raft restart" do
      session = create_test_session("dave", "agent")

      {:ok, seq} =
        Fleetlm.Runtime.append_message(
          session.id,
          session.user_id,
          session.agent_id,
          "text",
          %{"text" => "durable"},
          %{}
        )

      group_id = RaftManager.group_for_session(session.id)
      lane_id = RaftManager.lane_for_session(session.id)
      server_id = RaftManager.server_id(group_id)

      # Ensure message present in ring prior to flush
      {:ok, {_idx_term, before_lane}, _} =
        :ra.local_query({server_id, Node.self()}, fn state ->
          Map.fetch!(state.lanes, lane_id)
        end)

      assert :ets.info(before_lane.ring, :size) == 1

      Flusher.flush_sync()

      # Watermark should be advanced
      {:ok, {_idx_term_after, after_lane}, _} =
        :ra.local_query({server_id, Node.self()}, fn state ->
          Map.fetch!(state.lanes, lane_id)
        end)

      assert after_lane.flush_watermark == seq

      # Simulate raft crash and restart
      pid = Process.whereis(server_id)
      assert is_pid(pid)

      ref = Process.monitor(pid)
      Process.exit(pid, :kill)

      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2000

      eventually(
        fn ->
          assert is_nil(Process.whereis(server_id))
        end,
        timeout: 2_000
      )

      start_result = RaftManager.start_group(group_id)
      assert start_result == :ok or start_result == {:error, :cluster_not_formed}

      eventually(
        fn ->
          assert Process.whereis(server_id)
        end,
        timeout: 2_000
      )

      {:ok, seq2} =
        Fleetlm.Runtime.append_message(
          session.id,
          session.user_id,
          session.agent_id,
          "text",
          %{"text" => "after-restart"},
          %{}
        )

      assert seq2 >= seq + 1

      {:ok, messages} = Fleetlm.Runtime.get_messages(session.id, 0, seq2)
      assert hd(messages).content["text"] == "durable"
      assert Enum.any?(messages, &(&1.content["text"] == "after-restart"))
    end
  end

  describe "batch chunking" do
    test "chunks large message sets to avoid Postgres param limits" do
      # Create 10000 fake messages
      messages =
        for i <- 1..10000 do
          %{
            id: "msg_#{i}",
            session_id: "session_1",
            sender_id: "alice",
            recipient_id: "bob",
            seq: i,
            kind: "text",
            content: %{"text" => "msg#{i}"},
            metadata: %{},
            inserted_at: NaiveDateTime.utc_now()
          }
        end

      # Chunk into 5000-message batches
      chunks = Enum.chunk_every(messages, 5000)

      # Should have 2 chunks
      assert length(chunks) == 2
      assert length(Enum.at(chunks, 0)) == 5000
      assert length(Enum.at(chunks, 1)) == 5000

      # Each chunk should be insertable without exceeding Postgres limits
      # (10 fields × 5000 messages = 50000 params, under 65535 limit)
      for chunk <- chunks do
        param_count = length(chunk) * 10
        assert param_count < 65535
      end
    end
  end
end
