defmodule Fleetlm.Runtime.SessionServerTest do
  use Fleetlm.TestCase

  alias Fleetlm.Runtime.SessionServer

  setup do
    session = create_test_session("alice", "bob")
    %{session: session}
  end

  describe "start_link/1" do
    test "starts a session server and marks session active", %{session: session} do
      {:ok, pid} = SessionServer.start_link(session.id)
      assert Process.alive?(pid)

      # Verify session is marked active
      reloaded = Repo.get(FleetLM.Storage.Model.Session, session.id)
      assert reloaded.status == "active"

      # Stop gracefully and wait for cleanup
      ref = Process.monitor(pid)
      GenServer.stop(pid, :normal)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
    end

    test "loads current sequence number from storage", %{session: session} do
      # Append some messages first
      slot = :erlang.phash2(session.id, 64)
      :ok = StorageAPI.append_message(session.id, 1, "alice", "bob", "text", %{"text" => "msg1"}, %{})
      :ok = StorageAPI.append_message(session.id, 2, "bob", "alice", "text", %{"text" => "msg2"}, %{})
      wait_for_flush(slot)

      # Start server - should load seq = 2
      {:ok, pid} = SessionServer.start_link(session.id)

      # Append should get seq = 3
      {:ok, message} =
        SessionServer.append_message(
          session.id,
          "alice",
          "text",
          %{"text" => "msg3"}
        )

      assert message.seq == 3

      # Stop gracefully and wait for cleanup
      ref = Process.monitor(pid)
      GenServer.stop(pid, :normal)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
    end
  end

  describe "append_message/2" do
    setup %{session: session} do
      {:ok, pid} = SessionServer.start_link(session.id)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :kill)
          Process.sleep(10)
        end
      end)

      %{pid: pid}
    end

    test "appends message with incremented sequence number", %{session: session} do
      {:ok, message} =
        SessionServer.append_message(
          session.id,
          "alice",
          "text",
          %{"text" => "hello"}
        )

      assert message.seq == 1
      assert message.sender_id == "alice"
      assert message.session_id == session.id
      assert message.content["text"] == "hello"
    end

    test "broadcasts message via PubSub", %{session: session} do
      Phoenix.PubSub.subscribe(Fleetlm.PubSub, "session:#{session.id}")

      {:ok, message} =
        SessionServer.append_message(
          session.id,
          "alice",
          "text",
          %{"text" => "hello"}
        )

      assert_receive {:session_message, broadcasted_message}
      assert broadcasted_message["seq"] == message.seq
      assert broadcasted_message["sender_id"] == "alice"
    end

    test "increments sequence across multiple appends", %{session: session} do
      {:ok, msg1} = SessionServer.append_message(session.id, "alice", "text", %{})
      {:ok, msg2} = SessionServer.append_message(session.id, "bob", "text", %{})
      {:ok, msg3} = SessionServer.append_message(session.id, "alice", "text", %{})

      assert msg1.seq == 1
      assert msg2.seq == 2
      assert msg3.seq == 3
    end

    test "determines recipient_id based on sender", %{session: session} do
      {:ok, msg1} =
        SessionServer.append_message(
          session.id,
          "alice",
          "text",
          %{"text" => "from alice"}
        )

      # Storage doesn't expose recipient_id in the returned message,
      # but we can verify it was persisted correctly
      slot = :erlang.phash2(session.id, 64)
      wait_for_flush(slot)

      {:ok, messages} = StorageAPI.get_messages(session.id, 0, 10)
      persisted = Enum.find(messages, &(&1.seq == msg1.seq))
      assert persisted.recipient_id == "bob"
    end

    test "persists message via Storage.API", %{session: session} do
      {:ok, message} =
        SessionServer.append_message(
          session.id,
          "alice",
          "text",
          %{"text" => "hello"}
        )

      # Flush and verify persistence
      slot = :erlang.phash2(session.id, 64)
      wait_for_flush(slot)

      {:ok, messages} = StorageAPI.get_messages(session.id, 0, 10)
      assert length(messages) == 1
      assert hd(messages).seq == message.seq
    end
  end

  describe "join/3" do
    setup %{session: session} do
      {:ok, pid} = SessionServer.start_link(session.id)

      on_exit(fn ->
        if Process.alive?(pid) do
          Process.exit(pid, :kill)
          Process.sleep(10)
        end
      end)

      %{pid: pid}
    end

    test "returns messages after last_seq", %{session: session} do
      # Append 5 messages
      for seq <- 1..5 do
        SessionServer.append_message(session.id, "alice", "text", %{"seq" => seq})
      end

      # Join with last_seq = 2
      {:ok, result} = SessionServer.join(session.id, "alice", last_seq: 2, limit: 10)

      messages = result.messages
      assert length(messages) == 3
      assert Enum.map(messages, & &1["seq"]) == [3, 4, 5]
    end

    test "respects limit parameter", %{session: session} do
      # Append 10 messages
      for _seq <- 1..10 do
        SessionServer.append_message(session.id, "alice", "text", %{})
      end

      {:ok, result} = SessionServer.join(session.id, "alice", last_seq: 0, limit: 5)

      assert length(result.messages) == 5
      assert Enum.map(result.messages, & &1["seq"]) == [1, 2, 3, 4, 5]
    end

    test "authorizes participants", %{session: session} do
      # Only alice (user) is authorized to join via channel
      assert {:ok, _} = SessionServer.join(session.id, "alice", last_seq: 0)

      # bob is the agent - agents don't join, they get webhooks
      assert {:error, :unauthorized} = SessionServer.join(session.id, "bob", last_seq: 0)

      # charlie is not a participant
      assert {:error, :unauthorized} = SessionServer.join(session.id, "charlie", last_seq: 0)
    end

    test "returns empty messages for new session", %{session: session} do
      {:ok, result} = SessionServer.join(session.id, "alice", last_seq: 0)
      assert result.messages == []
    end
  end

  # Note: Drain tests are skipped because async Task.async in SlotLogServer.flush_to_database
  # doesn't automatically inherit :shared sandbox mode. Drain functionality will be tested
  # in integration tests where we can use real DB transactions.
  #
  # describe "drain/1" do
  #   test "flushes slot log and marks session inactive"
  #   test "broadcasts drain event"
  # end
end
