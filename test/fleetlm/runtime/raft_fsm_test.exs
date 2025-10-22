defmodule Fleetlm.Runtime.RaftFSMTest do
  use Fleetlm.TestCase

  import Ecto.Query

  alias Fleetlm.Runtime.RaftFSM
  alias Fleetlm.Runtime.RaftFSM.Conversation
  alias Fleetlm.Storage.AgentCache
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

    test "restores state from latest snapshot when available" do
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

      conversation = %Conversation{
        last_seq: 3,
        last_sent_seq: 2,
        user_id: "alice",
        agent_id: "agent:bob",
        last_activity: now
      }

      snapshot = %{
        group_id: 7,
        raft_index: 128,
        lanes: [
          %{
            lane_id: 0,
            messages: [
              %{
                id: "msg-3",
                session_id: "session-123",
                seq: 3,
                sender_id: "alice",
                recipient_id: "agent:bob",
                kind: "text",
                content: %{"text" => "restored"},
                metadata: %{},
                inserted_at: now
              }
            ],
            conversations: %{"session-123" => conversation},
            flush_watermark: 2,
            last_flushed_index: 100
          }
        ]
      }

      Repo.insert_all("raft_snapshots", [
        %{
          group_id: 7,
          raft_index: 128,
          snapshot_data: :erlang.term_to_binary(snapshot),
          created_at: now
        }
      ])

      on_exit(fn ->
        Repo.delete_all(from(s in "raft_snapshots", where: s.group_id == 7))
      end)

      state = RaftFSM.init(%{group_id: 7})

      assert state.group_id == 7
      assert state.last_snapshot_index == 128

      lane = state.lanes[0]
      assert lane.flush_watermark == 2
      assert :ets.info(lane.ring, :size) == 1
      assert lane.conversations["session-123"].last_seq == 3
    end

    test "falls back to cold start when snapshot cannot be decoded" do
      Repo.insert_all("raft_snapshots", [
        %{
          group_id: 9,
          raft_index: 64,
          snapshot_data: <<1, 2, 3, 4>>,
          created_at: NaiveDateTime.utc_now()
        }
      ])

      on_exit(fn ->
        Repo.delete_all(from(s in "raft_snapshots", where: s.group_id == 9))
      end)

      state = RaftFSM.init(%{group_id: 9})

      assert state.group_id == 9
      assert state.last_snapshot_index == 0

      assert Enum.all?(state.lanes, fn {_lane_id, lane} ->
               :ets.info(lane.ring, :size) == 0 and map_size(lane.conversations) == 0
             end)
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

      {new_state, {:reply, {:ok, results}}, _effects} =
        RaftFSM.apply(meta, {:append_batch, lane, frames}, state)

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

      {new_state, {:reply, {:ok, results}}, _} =
        RaftFSM.apply(meta, {:append_batch, lane, frames}, state)

      # Should assign seq 2 (bootstrapped from DB: max(seq) = 1)
      assert [{_session_id, seq, _message_id}] = results
      assert seq == 2

      # Conversation should be cached
      conversation = new_state.lanes[lane].conversations[session.id]
      assert conversation.last_seq == 2

      # Second append should NOT query DB again (already cached)
      frames2 = [{session.id, "alice", "bob", "text", %{"text" => "third"}, %{}}]
      meta2 = %{index: 2, term: 1}

      {final_state, {:reply, {:ok, results2}}, _} =
        RaftFSM.apply(meta2, {:append_batch, lane, frames2}, new_state)

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

      {new_state, {:reply, {:ok, results}}, _} =
        RaftFSM.apply(meta, {:append_batch, lane, frames}, state)

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

          {new_state, {:reply, {:ok, _}}, _} =
            RaftFSM.apply(meta, {:append_batch, lane, frames}, acc_state)

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

    test "bootstraps missing session with placeholder metadata", %{state: state} do
      lane = 0
      session_id = "missing-session"
      frames = [{session_id, "user", "agent", "text", %{"text" => "hello"}, %{}}]
      meta = %{index: 1, term: 1}

      {new_state, {:reply, {:ok, results}}, _effects} =
        RaftFSM.apply(meta, {:append_batch, lane, frames}, state)

      assert [{^session_id, seq, _message_id}] = results
      assert seq == 1

      conversation = new_state.lanes[lane].conversations[session_id]
      assert conversation.user_id == "unknown"
      assert conversation.agent_id == nil
    end

    test "enqueues webhook job when agent webhooks enabled", %{state: state, session: session} do
      previous = Application.get_env(:fleetlm, :disable_agent_webhooks)
      Application.put_env(:fleetlm, :disable_agent_webhooks, false)

      on_exit(fn ->
        Application.put_env(:fleetlm, :disable_agent_webhooks, previous)
      end)

      lane = 0
      session_id = session.id
      frames = [{session_id, session.user_id, session.agent_id, "text", %{"text" => "ping"}, %{}}]
      meta = %{index: 260, term: 1}

      {new_state, {:reply, {:ok, results}}, effects} =
        RaftFSM.apply(meta, {:append_batch, lane, frames}, state)

      assert [{^session_id, 1, _message_id}] = results

      assert Enum.any?(effects, fn
               {:mod_call, Fleetlm.Webhook.WorkerSupervisor, :ensure_catch_up,
                [^session_id, payload]} ->
                 payload.epoch == 1 and payload.target_seq == 1

               _ ->
                 false
             end)

      conversation = new_state.lanes[lane].conversations[session_id]
      assert conversation.state == :catching_up
      assert conversation.work_epoch == 1
      assert conversation.last_sent_seq == 0

      # Snapshot effect should trigger when index jumps beyond threshold
      assert Enum.any?(effects, fn
               {:release_cursor, 260, :snapshot} -> true
               _ -> false
             end)
    end

    test "restarts webhook job after processing completes", %{state: state, session: session} do
      previous = Application.get_env(:fleetlm, :disable_agent_webhooks)
      Application.put_env(:fleetlm, :disable_agent_webhooks, false)

      on_exit(fn ->
        Application.put_env(:fleetlm, :disable_agent_webhooks, previous)
      end)

      lane = 0
      session_id = session.id

      frames = [
        {session_id, session.user_id, session.agent_id, "text", %{"text" => "first"}, %{}}
      ]

      meta = %{index: 1, term: 1}

      {state_after_first, {:reply, {:ok, _}}, _effects} =
        RaftFSM.apply(meta, {:append_batch, lane, frames}, state)

      conversation_after_first = state_after_first.lanes[lane].conversations[session_id]

      {state_idle, :ok, _} =
        RaftFSM.apply(
          %{index: 2, term: 1},
          {:agent_caught_up, lane, session_id, conversation_after_first.work_epoch, 1},
          state_after_first
        )

      frames2 = [
        {session_id, session.user_id, session.agent_id, "text", %{"text" => "second"}, %{}}
      ]

      meta2 = %{index: 3, term: 1}

      {_state_final, {:reply, {:ok, _}}, effects2} =
        RaftFSM.apply(meta2, {:append_batch, lane, frames2}, state_idle)

      assert Enum.any?(effects2, fn
               {:mod_call, Fleetlm.Webhook.WorkerSupervisor, :ensure_catch_up,
                [^session_id, payload]} ->
                 payload.epoch == 2 and payload.target_seq == 2

               _ ->
                 false
             end)
    end

    test "restarts webhook job after processing failure", %{state: state, session: session} do
      previous = Application.get_env(:fleetlm, :disable_agent_webhooks)
      Application.put_env(:fleetlm, :disable_agent_webhooks, false)

      on_exit(fn ->
        Application.put_env(:fleetlm, :disable_agent_webhooks, previous)
      end)

      lane = 0
      session_id = session.id

      frames = [
        {session_id, session.user_id, session.agent_id, "text", %{"text" => "first"}, %{}}
      ]

      meta = %{index: 1, term: 1}

      {state_after_first, {:reply, {:ok, _}}, _effects} =
        RaftFSM.apply(meta, {:append_batch, lane, frames}, state)

      conversation_after_first = state_after_first.lanes[lane].conversations[session_id]

      {state_idle, :ok} =
        RaftFSM.apply(
          %{index: 2, term: 1},
          {:agent_catchup_failed, lane, session_id, conversation_after_first.work_epoch,
           :timeout},
          state_after_first
        )

      frames2 = [
        {session_id, session.user_id, session.agent_id, "text", %{"text" => "second"}, %{}}
      ]

      meta2 = %{index: 3, term: 1}

      {_state_final, {:reply, {:ok, _}}, effects2} =
        RaftFSM.apply(meta2, {:append_batch, lane, frames2}, state_idle)

      assert Enum.any?(effects2, fn
               {:mod_call, Fleetlm.Webhook.WorkerSupervisor, :ensure_catch_up,
                [^session_id, payload]} ->
                 payload.epoch == 2 and payload.target_seq == 2

               _ ->
                 false
             end)
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

      {state_with_messages, {:reply, {:ok, _}}, _} =
        RaftFSM.apply(meta, {:append_batch, lane, frames}, state)

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

      {state_with_messages, {:reply, {:ok, _}}, _} =
        RaftFSM.apply(meta, {:append_batch, lane, frames}, state)

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

      {state_with_messages, {:reply, {:ok, _}}, _} =
        RaftFSM.apply(meta, {:append_batch, lane, frames}, state)

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

  describe "apply/3 - auxiliary commands" do
    test "update_sent_seq is a no-op when conversation missing" do
      state = RaftFSM.init(%{group_id: 0})

      {new_state, :ok} =
        RaftFSM.apply(%{index: 1, term: 1}, {:update_sent_seq, 0, "unknown-session", 5}, state)

      assert new_state == state
    end

    test "agent_catchup_failed resets conversation state to idle" do
      now = NaiveDateTime.utc_now()
      session_id = "session-failed"
      lane_id = 0

      state = RaftFSM.init(%{group_id: 0})
      lane = state.lanes[lane_id]

      conversation = %Conversation{
        last_seq: 3,
        last_sent_seq: 2,
        user_id: "alice",
        agent_id: "agent:bob",
        last_activity: now,
        state: :catching_up,
        work_epoch: 1
      }

      lane = %{lane | conversations: Map.put(lane.conversations, session_id, conversation)}
      state = put_in(state.lanes[lane_id], lane)

      {new_state, :ok} =
        RaftFSM.apply(
          %{index: 5, term: 1},
          {:agent_catchup_failed, lane_id, session_id, 1, :timeout},
          state
        )

      assert new_state.lanes[lane_id].conversations[session_id].state == :idle
    end

    test "agent_caught_up triggers compaction when thresholds met" do
      now = NaiveDateTime.utc_now()
      agent_id = "agent:compact"

      {:ok, _agent} =
        Fleetlm.Agent.create(%{
          id: agent_id,
          name: "Compaction Agent",
          origin_url: "https://example.com",
          webhook_path: "/webhook",
          compaction_enabled: true,
          compaction_token_budget: 10,
          compaction_trigger_ratio: 0.5,
          compaction_webhook_url: "https://example.com/compact"
        })

      AgentCache.clear_all()

      state = RaftFSM.init(%{group_id: 0})
      lane_id = 0
      session_id = "session-compact"

      conversation = %Conversation{
        state: :catching_up,
        work_epoch: 1,
        last_seq: 3,
        last_sent_seq: 1,
        user_id: "alice",
        agent_id: agent_id,
        last_activity: now,
        tokens_since_summary: 10,
        last_compacted_seq: 0
      }

      lane = state.lanes[lane_id]
      lane = %{lane | conversations: Map.put(lane.conversations, session_id, conversation)}
      state = put_in(state.lanes[lane_id], lane)

      {new_state, :ok, effects} =
        RaftFSM.apply(
          %{index: 6, term: 1},
          {:agent_caught_up, lane_id, session_id, 1, 3},
          state
        )

      updated = new_state.lanes[lane_id].conversations[session_id]
      assert updated.state == :compacting
      assert updated.last_sent_seq == 3

      assert Enum.any?(effects, fn
               {:mod_call, Fleetlm.Webhook.WorkerSupervisor, :ensure_compaction,
                [^session_id, %{epoch: 2, job: job}]} ->
                 job[:payload][:range_end] == 3

               _ ->
                 false
             end)
    end

    test "compaction_failed resumes pending user message" do
      now = NaiveDateTime.utc_now()
      lane_id = 0
      session_id = "session-compaction-failed"

      state = RaftFSM.init(%{group_id: 0})
      lane = state.lanes[lane_id]

      conversation = %Conversation{
        state: :compacting,
        work_epoch: 1,
        pending_user_seq: 5,
        pending_epoch: 2,
        last_seq: 5,
        last_sent_seq: 4,
        user_id: "alice",
        agent_id: "agent:bob",
        last_activity: now
      }

      lane = %{lane | conversations: Map.put(lane.conversations, session_id, conversation)}
      state = put_in(state.lanes[lane_id], lane)

      {new_state, :ok, effects} =
        RaftFSM.apply(
          %{index: 7, term: 1},
          {:compaction_failed, lane_id, session_id, 1, :timeout},
          state
        )

      updated = new_state.lanes[lane_id].conversations[session_id]
      assert updated.state == :catching_up
      assert updated.pending_user_seq == nil
      assert updated.work_epoch == 2

      assert Enum.any?(effects, fn
               {:mod_call, Fleetlm.Webhook.WorkerSupervisor, :ensure_catch_up,
                [^session_id, payload]} ->
                 payload.target_seq == 5 and payload.epoch == 2

               _ ->
                 false
             end)
    end

    test "evict_inactive_conversations removes stale entries" do
      session = create_test_session("alice", "bob")
      state = RaftFSM.init(%{group_id: 0})
      lane_id = 0

      frames = [
        {session.id, session.user_id, session.agent_id, "text", %{"text" => "fresh"}, %{}}
      ]

      {state_with_conv, {:reply, {:ok, _}}, _effects} =
        RaftFSM.apply(%{index: 1, term: 1}, {:append_batch, lane_id, frames}, state)

      stale_time = ~N[2000-01-01 00:00:00]

      lane = state_with_conv.lanes[lane_id]
      conversation = lane.conversations[session.id]
      stale_conversation = %{conversation | last_activity: stale_time}

      updated_lane =
        %{lane | conversations: Map.put(lane.conversations, session.id, stale_conversation)}

      state_with_stale = put_in(state_with_conv.lanes[lane_id], updated_lane)

      {new_state, :ok} =
        RaftFSM.apply(%{index: 2, term: 1}, {:evict_inactive_conversations}, state_with_stale)

      assert new_state.lanes[lane_id].conversations == %{}
    end
  end

  describe "restore/1" do
    test "falls back to cold start when binary cannot be decoded" do
      state = RaftFSM.restore(<<0, 1, 2>>)

      assert state.group_id == 0

      assert Enum.all?(state.lanes, fn {_lane_id, lane} ->
               :ets.info(lane.ring, :size) == 0 and map_size(lane.conversations) == 0
             end)
    end
  end
end
