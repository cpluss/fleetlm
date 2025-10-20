defmodule Fleetlm.Runtime.RaftFSMTest do
  use Fleetlm.TestCase

  alias Fleetlm.Runtime.RaftFSM
  alias Fleetlm.Storage.Model.Message

  describe "init/1" do
    test "cold start creates empty lanes" do
      state = RaftFSM.init(%{group_id: 0})

      assert state.group_id == 0
      assert map_size(state.lanes) == 16

      # Each lane should be empty
      for {_lane_id, lane} <- state.lanes do
        assert map_size(lane.conversations) == 0
        assert lane.flush_watermark == 0
        assert :ets.info(lane.ring, :size) == 0
      end
    end
  end

  describe "apply/3 - append_batch" do
    setup do
      # Create a test session in DB for bootstrap
      session = create_test_session("alice", "bob")
      state = RaftFSM.init(%{group_id: 0})
      %{state: state, session: session}
    end

    test "appends message and assigns sequence", %{state: state, session: session} do
      lane = 0
      frames = [{session.id, "alice", "bob", "text", %{"text" => "hello"}, %{}}]

      meta = %{index: 1, term: 1}
      {new_state, {:reply, {:ok, results}}, _effects} = RaftFSM.apply(meta, {:append_batch, lane, frames}, state)

      # Should return assigned sequence and message ID
      assert [{session_id, seq, message_id}] = results
      assert session_id == session.id
      assert seq == 1
      assert is_binary(message_id)

      # Should be in ETS ring
      lane_state = new_state.lanes[lane]
      assert :ets.info(lane_state.ring, :size) == 1

      # Should cache conversation metadata
      conversation = lane_state.conversations[session.id]
      assert conversation.last_seq == 1
      assert conversation.user_id == session.user_id
      assert conversation.agent_id == session.agent_id
    end

    test "bootstraps conversation from DB only once", %{state: state, session: session} do
      # Pre-populate DB with messages
      Repo.insert_all(Message, [
        %{
          id: Uniq.UUID.uuid7(:slug),
          session_id: session.id,
          sender_id: "alice",
          recipient_id: "bob",
          seq: 1,
          kind: "text",
          content: %{"text" => "existing"},
          metadata: %{},
          shard_key: 0,
          inserted_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
        }
      ])

      lane = 0
      frames = [{session.id, "alice", "bob", "text", %{"text" => "new"}, %{}}]

      meta = %{index: 1, term: 1}
      {new_state, {:reply, {:ok, results}}, _} = RaftFSM.apply(meta, {:append_batch, lane, frames}, state)

      # Should assign seq 2 (bootstrapped from DB: max(seq) = 1)
      assert [{_session_id, seq, _message_id}] = results
      assert seq == 2

      # Conversation should be cached
      conversation = new_state.lanes[lane].conversations[session.id]
      assert conversation.last_seq == 2

      # Second append should NOT query DB again (already cached)
      frames2 = [{session.id, "alice", "bob", "text", %{"text" => "third"}, %{}}]
      meta2 = %{index: 2, term: 1}
      {final_state, {:reply, {:ok, results2}}, _} = RaftFSM.apply(meta2, {:append_batch, lane, frames2}, new_state)

      # Should assign seq 3 (incremented from cached last_seq = 2)
      assert [{_session_id, seq2, _message_id}] = results2
      assert seq2 == 3

      # Verify no extra DB queries (just check state is correct)
      conversation2 = final_state.lanes[lane].conversations[session.id]
      assert conversation2.last_seq == 3
    end

    test "handles multiple messages in batch", %{state: state, session: session} do
      lane = 0

      frames = [
        {session.id, "alice", "bob", "text", %{"text" => "msg1"}, %{}},
        {session.id, "alice", "bob", "text", %{"text" => "msg2"}, %{}},
        {session.id, "alice", "bob", "text", %{"text" => "msg3"}, %{}}
      ]

      meta = %{index: 1, term: 1}
      {new_state, {:reply, {:ok, results}}, _} = RaftFSM.apply(meta, {:append_batch, lane, frames}, state)

      # Should assign consecutive sequences
      assert length(results) == 3
      assert Enum.map(results, fn {_, seq, _} -> seq end) == [1, 2, 3]

      # All messages should be in ETS ring
      lane_state = new_state.lanes[lane]
      assert :ets.info(lane_state.ring, :size) == 3

      # Conversation last_seq should be 3
      assert lane_state.conversations[session.id].last_seq == 3
    end

    test "trims ring when capacity exceeded", %{state: state, session: session} do
      lane = 0

      # Append 5100 messages (capacity = 5000)
      state_with_messages =
        Enum.reduce(1..5100, state, fn i, acc_state ->
          frames = [{session.id, "alice", "bob", "text", %{"text" => "msg#{i}"}, %{}}]
          meta = %{index: i, term: 1}
          {new_state, {:reply, {:ok, _}}, _} = RaftFSM.apply(meta, {:append_batch, lane, frames}, acc_state)
          new_state
        end)

      # Ring should be trimmed to capacity
      lane_state = state_with_messages.lanes[lane]
      ring_size = :ets.info(lane_state.ring, :size)
      assert ring_size == 5000

      # Oldest messages should be evicted (ring should have last 5000)
      first_key = :ets.first(lane_state.ring)
      assert first_key == 5100 - 5000 + 1
    end
  end

  describe "apply/3 - advance_watermark" do
    setup do
      session = create_test_session("alice", "bob")
      state = RaftFSM.init(%{group_id: 0})

      # Add some messages to the ring
      lane = 0
      frames = [
        {session.id, "alice", "bob", "text", %{"text" => "msg1"}, %{}},
        {session.id, "alice", "bob", "text", %{"text" => "msg2"}, %{}},
        {session.id, "alice", "bob", "text", %{"text" => "msg3"}, %{}}
      ]

      meta = %{index: 1, term: 1}
      {state_with_messages, {:reply, {:ok, _}}, _} = RaftFSM.apply(meta, {:append_batch, lane, frames}, state)

      %{state: state_with_messages, session: session}
    end

    test "advances watermark and deletes old entries", %{state: state, session: _session} do
      lane = 0

      # Advance watermark to seq 2
      meta = %{index: 2, term: 1}
      {new_state, :ok} = RaftFSM.apply(meta, {:advance_watermark, lane, 2}, state)

      # Watermark should be updated
      assert new_state.lanes[lane].flush_watermark == 2

      # Entries ≤ 2 should be deleted from ring
      ring = new_state.lanes[lane].ring
      assert :ets.info(ring, :size) == 1

      # Only seq 3 should remain
      assert :ets.first(ring) == 3
    end
  end

  describe "apply/3 - force_snapshot" do
    test "forces snapshot and updates tracking" do
      state = RaftFSM.init(%{group_id: 0})
      meta = %{index: 10, term: 1}

      {new_state, {:reply, :ok}, effects} = RaftFSM.apply(meta, :force_snapshot, state)

      assert new_state.last_snapshot_index == 10
      assert is_integer(new_state.last_snapshot_time)

      assert effects == [{:release_cursor, 10, :snapshot}]
    end
  end

  describe "query_messages/4" do
    setup do
      session = create_test_session("alice", "bob")
      state = RaftFSM.init(%{group_id: 0})

      # Add messages
      lane = 0
      frames = [
        {session.id, "alice", "bob", "text", %{"text" => "msg1"}, %{}},
        {session.id, "alice", "bob", "text", %{"text" => "msg2"}, %{}},
        {session.id, "alice", "bob", "text", %{"text" => "msg3"}, %{}}
      ]

      meta = %{index: 1, term: 1}
      {state_with_messages, {:reply, {:ok, _}}, _} = RaftFSM.apply(meta, {:append_batch, lane, frames}, state)

      %{state: state_with_messages, session: session}
    end

    test "returns messages for session after_seq", %{state: state, session: session} do
      lane = 0

      messages = RaftFSM.query_messages(state, lane, session.id, 1)

      # Should get messages 2 and 3
      assert length(messages) == 2
      assert Enum.at(messages, 0).seq == 2
      assert Enum.at(messages, 1).seq == 3
    end

    test "returns empty list when no matching messages", %{state: state} do
      lane = 0
      fake_session_id = Uniq.UUID.uuid7(:slug)

      messages = RaftFSM.query_messages(state, lane, fake_session_id, 0)

      assert messages == []
    end
  end

  describe "query_unflushed/1" do
    setup do
      session = create_test_session("alice", "bob")
      state = RaftFSM.init(%{group_id: 0})

      # Add messages to lane 0
      lane = 0
      frames = [
        {session.id, "alice", "bob", "text", %{"text" => "msg1"}, %{}},
        {session.id, "alice", "bob", "text", %{"text" => "msg2"}, %{}},
        {session.id, "alice", "bob", "text", %{"text" => "msg3"}, %{}}
      ]

      meta = %{index: 1, term: 1}
      {state_with_messages, {:reply, {:ok, _}}, _} = RaftFSM.apply(meta, {:append_batch, lane, frames}, state)

      %{state: state_with_messages, session: session}
    end

    test "returns all messages when watermark = 0", %{state: state} do
      unflushed = RaftFSM.query_unflushed(state)

      # Should have lane 0 with 3 messages
      assert map_size(unflushed) == 1
      assert length(unflushed[0]) == 3
    end

    test "returns only messages > watermark", %{state: state} do
      # Advance watermark to 2
      lane = 0
      meta = %{index: 2, term: 1}
      {new_state, :ok} = RaftFSM.apply(meta, {:advance_watermark, lane, 2}, state)

      unflushed = RaftFSM.query_unflushed(new_state)

      # Should only have message 3
      assert map_size(unflushed) == 1
      assert length(unflushed[0]) == 1
      assert hd(unflushed[0]).seq == 3
    end

    test "returns empty map when all messages flushed", %{state: state} do
      # Advance watermark past all messages
      lane = 0
      meta = %{index: 2, term: 1}
      {new_state, :ok} = RaftFSM.apply(meta, {:advance_watermark, lane, 999}, state)

      unflushed = RaftFSM.query_unflushed(new_state)

      # Should be empty
      assert unflushed == %{}
    end
  end
end
