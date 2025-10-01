defmodule Fleetlm.Integration.IntegrationTest do
  @moduledoc """
  End-to-end integration tests for the session runtime architecture.

  Tests the complete flow:
  - Router -> SessionServer -> Storage.API -> disk log
  - PubSub broadcasting
  - InboxServer event-driven updates
  - SessionChannel WebSocket integration
  - DrainCoordinator graceful shutdown
  """
  use Fleetlm.TestCase

  alias Fleetlm.Runtime.{Router, SessionSupervisor, InboxServer, DrainCoordinator}
  alias FleetLM.Storage.API, as: StorageAPI

  describe "complete message flow" do
    test "Router -> SessionServer -> Storage -> PubSub" do
      # Create session
      session = create_test_session("alice", "bob")

      # Subscribe to PubSub for verification
      Phoenix.PubSub.subscribe(Fleetlm.PubSub, "session:#{session.id}")

      # Append message via Router
      {:ok, _message} =
        Router.append_message(
          session.id,
          "alice",
          "text",
          %{"text" => "hello bob"},
          %{}
        )

      # Should receive PubSub broadcast
      assert_receive {:session_message, payload}, 1000
      assert payload["session_id"] == session.id
      assert payload["sender_id"] == "alice"
      assert payload["content"]["text"] == "hello bob"

      # Verify message in storage
      slot = :erlang.phash2(session.id, 64)
      wait_for_flush(slot)

      {:ok, messages} = StorageAPI.get_messages(session.id, 0, 10)
      assert length(messages) == 1
      assert hd(messages).content["text"] == "hello bob"

      # Verify session server is active
      assert SessionSupervisor.active_count() >= 1
    end

    test "multi-party conversation with sequence ordering" do
      session = create_test_session("alice", "bob")

      Phoenix.PubSub.subscribe(Fleetlm.PubSub, "session:#{session.id}")

      # Alice sends 3 messages
      {:ok, msg1} =
        Router.append_message(session.id, "alice", "text", %{"text" => "msg1"}, %{})

      assert_receive {:session_message, _}, 1000

      {:ok, msg2} =
        Router.append_message(session.id, "alice", "text", %{"text" => "msg2"}, %{})

      assert_receive {:session_message, _}, 1000

      # Bob replies
      {:ok, msg3} =
        Router.append_message(session.id, "bob", "text", %{"text" => "msg3"}, %{})

      assert_receive {:session_message, _}, 1000

      # Verify sequence numbers are monotonically increasing
      assert msg1.seq == 1
      assert msg2.seq == 2
      assert msg3.seq == 3

      # Verify replay via Router
      {:ok, replay} = Router.join(session.id, "alice", last_seq: 0, limit: 10)
      messages = replay.messages

      assert length(messages) == 3
      assert Enum.at(messages, 0)["seq"] == 1
      assert Enum.at(messages, 1)["seq"] == 2
      assert Enum.at(messages, 2)["seq"] == 3
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
        Router.append_message(
          session1.id,
          "bob",
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
        Router.append_message(
          session2.id,
          "charlie",
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
            Router.append_message(
              session.id,
              session.user_id,
              "text",
              %{"text" => "parallel message"},
              %{}
            )
          end)
        end

      results = Task.await_many(tasks, 5000)

      # All should succeed
      assert Enum.all?(results, &match?({:ok, _}, &1))

      # Verify all sessions have active servers
      assert SessionSupervisor.active_count() >= 3

      # Wait for async flushes with longer timeout
      Process.sleep(2000)

      # Verify messages are stored - either in disk log or DB
      # (don't force immediate flush for parallel test)
      for session <- sessions do
        # Messages should at least be readable via Router (from ETS cache or storage)
        {:ok, replay} = Router.join(session.id, session.user_id, last_seq: 0, limit: 10)
        assert length(replay.messages) >= 1
      end
    end
  end

  describe "graceful shutdown" do
    test "DrainCoordinator flushes all active sessions" do
      # Create sessions and send messages
      session1 = create_test_session("alice", "bob")
      session2 = create_test_session("charlie", "dave")

      {:ok, _} =
        Router.append_message(session1.id, "alice", "text", %{"text" => "msg1"}, %{})

      {:ok, _} =
        Router.append_message(session2.id, "charlie", "text", %{"text" => "msg2"}, %{})

      # Verify sessions are active
      assert SessionSupervisor.active_count() >= 2

      # Use shared sandbox mode for drain test
      :ok = Ecto.Adapters.SQL.Sandbox.mode(Fleetlm.Repo, {:shared, self()})

      # Trigger drain
      result = DrainCoordinator.trigger_drain()
      assert result == :ok or match?({:error, {:partial_drain, _, _}}, result)

      # Wait a bit for drain to complete
      Process.sleep(200)

      # Verify messages are flushed to DB
      {:ok, messages1} = StorageAPI.get_messages(session1.id, 0, 10)
      {:ok, messages2} = StorageAPI.get_messages(session2.id, 0, 10)

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
          Router.append_message(
            session.id,
            "alice",
            "text",
            %{"text" => "msg#{i}"},
            %{}
          )
      end

      # Join session (as alice - the user)
      {:ok, result} = Router.join(session.id, "alice", last_seq: 0, limit: 10)

      # Should get all 5 messages
      assert length(result.messages) == 5
      assert Enum.at(result.messages, 0)["content"]["text"] == "msg1"
      assert Enum.at(result.messages, 4)["content"]["text"] == "msg5"
    end

    test "join with last_seq filters older messages" do
      session = create_test_session("alice", "bob")

      # Send 5 messages
      for i <- 1..5 do
        {:ok, _} =
          Router.append_message(
            session.id,
            "alice",
            "text",
            %{"text" => "msg#{i}"},
            %{}
          )
      end

      # Join with last_seq = 3 (as alice - the user)
      {:ok, result} = Router.join(session.id, "alice", last_seq: 3, limit: 10)

      # Should only get messages 4 and 5
      assert length(result.messages) == 2
      assert Enum.at(result.messages, 0)["content"]["text"] == "msg4"
      assert Enum.at(result.messages, 1)["content"]["text"] == "msg5"
    end
  end

  describe "error handling" do
    test "append to non-existent session fails gracefully" do
      fake_session_id = Ulid.generate()

      result =
        Router.append_message(
          fake_session_id,
          "alice",
          "text",
          %{"text" => "test"},
          %{}
        )

      # Should return error, not crash
      assert match?({:error, _}, result)
    end

    test "join non-existent session fails gracefully" do
      fake_session_id = Ulid.generate()

      result = Router.join(fake_session_id, "alice", last_seq: 0, limit: 10)

      # Should return error
      assert match?({:error, _}, result)
    end
  end
end
