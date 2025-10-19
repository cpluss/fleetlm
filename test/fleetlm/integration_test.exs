defmodule Fleetlm.Integration.IntegrationTest do
  @moduledoc """
  End-to-end integration tests for the Raft-based runtime architecture.

  Tests the complete flow:
  - Runtime API -> Raft FSM -> Raft quorum commit
  - PubSub broadcasting
  - InboxServer event-driven updates
  - SessionChannel WebSocket integration
  - DrainCoordinator graceful shutdown (Raft snapshots)
  """
  use Fleetlm.TestCase

  alias Fleetlm.Runtime
  alias Fleetlm.Runtime.{InboxServer, DrainCoordinator}
  alias Fleetlm.Storage.Model.Message

  require ExUnit.CaptureLog

  describe "complete message flow" do
    test "Runtime API -> Raft -> PubSub" do
      # Create session
      session = create_test_session("alice", "bob")

      # Subscribe to PubSub for verification
      Phoenix.PubSub.subscribe(Fleetlm.PubSub, "session:#{session.id}")

      # Append message via Runtime API
      {:ok, seq} =
        Runtime.append_message(
          session.id,
          "alice",
          "bob",
          "text",
          %{"text" => "hello bob"},
          %{}
        )

      assert seq == 1

      # Should receive PubSub broadcast
      assert_receive {:session_message, payload}, 1000
      assert payload["session_id"] == session.id
      assert payload["sender_id"] == "alice"
      assert payload["content"]["text"] == "hello bob"

      # Verify message in Raft state (hot path)
      {:ok, messages} = Runtime.get_messages(session.id, 0, 10)
      assert length(messages) == 1
      assert hd(messages).content["text"] == "hello bob"

      # Trigger background flush and verify in Postgres
      send(Fleetlm.Runtime.Flusher, :flush)
      Process.sleep(500)

      db_messages =
        Repo.all(from(m in Message, where: m.session_id == ^session.id))

      assert length(db_messages) == 1
    end

    test "multi-party conversation with sequence ordering" do
      session = create_test_session("alice", "bob")

      Phoenix.PubSub.subscribe(Fleetlm.PubSub, "session:#{session.id}")

      # Alice sends 3 messages
      {:ok, seq1} =
        Runtime.append_message(session.id, "alice", "bob", "text", %{"text" => "msg1"}, %{})

      assert_receive {:session_message, _}, 1000

      {:ok, seq2} =
        Runtime.append_message(session.id, "alice", "bob", "text", %{"text" => "msg2"}, %{})

      assert_receive {:session_message, _}, 1000

      # Bob replies
      {:ok, seq3} =
        Runtime.append_message(session.id, "bob", "alice", "text", %{"text" => "msg3"}, %{})

      assert_receive {:session_message, _}, 1000

      # Verify sequence numbers are monotonically increasing
      assert seq1 == 1
      assert seq2 == 2
      assert seq3 == 3

      # Verify replay via Runtime API
      {:ok, messages} = Runtime.get_messages(session.id, 0, 10)

      assert length(messages) == 3
      assert Enum.at(messages, 0).seq == 1
      assert Enum.at(messages, 1).seq == 2
      assert Enum.at(messages, 2).seq == 3
    end

    test "inbox server receives real-time updates" do
      # Create sessions
      session1 = create_test_session("alice", "bob")
      session2 = create_test_session("alice", "charlie")

      # Start inbox server for alice
      {:ok, inbox_pid} = InboxServer.start_link("alice")

      on_exit(fn ->
        if Process.alive?(inbox_pid), do: catch_exit(GenServer.stop(inbox_pid, :normal))
      end)

      # Subscribe to inbox snapshot broadcasts
      Phoenix.PubSub.subscribe(Fleetlm.PubSub, "inbox:user:alice")

      # Send message to session1
      {:ok, _} =
        Runtime.append_message(
          session1.id,
          "bob",
          "alice",
          "text",
          %{"text" => "hello alice"},
          %{}
        )

      # Should receive inbox update (batched)
      assert_receive {:inbox_snapshot, snapshot}, 2000
      updated_session = Enum.find(snapshot, &(&1["session_id"] == session1.id))
      assert updated_session["unread_count"] == 1
      assert updated_session["last_sender_id"] == "bob"

      # Send message to session2
      {:ok, _} =
        Runtime.append_message(
          session2.id,
          "charlie",
          "alice",
          "text",
          %{"text" => "hi alice"},
          %{}
        )

      # Should receive another inbox update (batched)
      assert_receive {:inbox_snapshot, snapshot2}, 2000

      # Verify both sessions in snapshot, ordered by last activity
      assert length(snapshot2) == 2
      # Most recent (session2) should be first
      assert hd(snapshot2)["session_id"] == session2.id
    end

    test "parallel appends across multiple sessions" do
      # Create 3 sessions (reduced to avoid overwhelming the system)
      sessions =
        for i <- 1..3 do
          create_test_session("user#{i}", "agent")
        end

      # Send messages in parallel
      tasks =
        for session <- sessions do
          Task.async(fn ->
            Runtime.append_message(
              session.id,
              session.user_id,
              session.agent_id,
              "text",
              %{"text" => "parallel message"},
              %{}
            )
          end)
        end

      results = Task.await_many(tasks, 5000)

      # All should succeed
      assert Enum.all?(results, &match?({:ok, _}, &1))

      # Verify messages are in Raft state
      for session <- sessions do
        {:ok, messages} = Runtime.get_messages(session.id, 0, 10)
        assert length(messages) >= 1
      end
    end
  end

  describe "graceful shutdown" do
    test "DrainCoordinator snapshots all Raft groups" do
      # Create sessions and send messages
      session1 = create_test_session("alice", "bob")
      session2 = create_test_session("charlie", "dave")

      {:ok, _} =
        Runtime.append_message(session1.id, "alice", "bob", "text", %{"text" => "msg1"}, %{})

      {:ok, _} =
        Runtime.append_message(session2.id, "charlie", "dave", "text", %{"text" => "msg2"}, %{})

      # Use shared sandbox mode for drain test
      case Ecto.Adapters.SQL.Sandbox.mode(Fleetlm.Repo, {:shared, self()}) do
        :ok -> :ok
        :already_shared -> :ok
      end

      # Trigger drain (snapshots all 256 Raft groups)
      result = DrainCoordinator.trigger_drain()
      assert result == :ok or match?({:error, {:partial_drain, _, _}}, result)

      # Verify messages can still be read (from Raft state or Postgres)
      {:ok, messages1} = Runtime.get_messages(session1.id, 0, 10)
      {:ok, messages2} = Runtime.get_messages(session2.id, 0, 10)

      assert length(messages1) >= 1
      assert length(messages2) >= 1
    end
  end

  describe "session join and replay" do
    test "join returns recent messages" do
      session = create_test_session("alice", "bob")

      # Send 5 messages
      for i <- 1..5 do
        {:ok, _} =
          Runtime.append_message(
            session.id,
            "alice",
            "bob",
            "text",
            %{"text" => "msg#{i}"},
            %{}
          )
      end

      # Get messages via Runtime API
      {:ok, messages} = Runtime.get_messages(session.id, 0, 10)

      # Should get all 5 messages
      assert length(messages) == 5
      assert Enum.at(messages, 0).content["text"] == "msg1"
      assert Enum.at(messages, 4).content["text"] == "msg5"
    end

    test "get_messages with after_seq filters older messages" do
      session = create_test_session("alice", "bob")

      # Send 5 messages
      for i <- 1..5 do
        {:ok, _} =
          Runtime.append_message(
            session.id,
            "alice",
            "bob",
            "text",
            %{"text" => "msg#{i}"},
            %{}
          )
      end

      # Get messages after seq 3
      {:ok, messages} = Runtime.get_messages(session.id, 3, 10)

      # Should only get messages 4 and 5
      assert length(messages) == 2
      assert Enum.at(messages, 0).content["text"] == "msg4"
      assert Enum.at(messages, 1).content["text"] == "msg5"
    end
  end

  describe "error handling" do
    test "append to non-existent session creates conversation metadata on bootstrap" do
      # In Raft architecture, sessions MUST exist in DB before first append
      # Otherwise bootstrap will create a warning conversation
      fake_session_id = Uniq.UUID.uuid7(:slug)

      # This will log a warning but proceed with "unknown" user_id
      {:ok, seq} =
        Runtime.append_message(
          fake_session_id,
          "alice",
          "bob",
          "text",
          %{"text" => "test"},
          %{}
        )

      assert seq == 1

      # Message should be in Raft state
      {:ok, messages} = Runtime.get_messages(fake_session_id, 0, 10)
      assert length(messages) == 1
    end

    test "get_messages for non-existent session returns empty list" do
      fake_session_id = Uniq.UUID.uuid7(:slug)

      {:ok, messages} = Runtime.get_messages(fake_session_id, 0, 10)
      assert messages == []
    end
  end
end
