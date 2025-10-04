defmodule Fleetlm.Storage.IntegrationTest do
  use Fleetlm.TestCase

  describe "complete message flow" do
    test "append -> flush -> retrieve" do
      # Create session using helper
      session = create_test_session("alice", "bob")
      assert session.user_id == "alice"
      assert session.agent_id == "bob"
      assert session.status == "active"

      # Append message (goes to disk_log)
      :ok =
        API.append_message(
          session.id,
          1,
          "alice",
          "bob",
          "text",
          %{"text" => "hello"},
          %{}
        )

      # Wait for flush using helper
      slot = :erlang.phash2(session.id, 64)
      wait_for_flush(slot)

      # Retrieve from database
      {:ok, messages} = API.get_messages(session.id, 0, 10)
      assert length(messages) == 1

      message = hd(messages)
      assert message.seq == 1
      assert message.sender_id == "alice"
      assert message.content["text"] == "hello"
    end

    test "appends multiple messages in sequence" do
      session = create_test_session("alice", "bob")

      # Append 3 messages
      :ok = API.append_message(session.id, 1, "alice", "bob", "text", %{"text" => "msg1"}, %{})
      :ok = API.append_message(session.id, 2, "bob", "alice", "text", %{"text" => "msg2"}, %{})
      :ok = API.append_message(session.id, 3, "alice", "bob", "text", %{"text" => "msg3"}, %{})

      # Flush using helper
      slot = :erlang.phash2(session.id, 64)
      wait_for_flush(slot)

      # Retrieve all messages
      {:ok, messages} = API.get_messages(session.id, 0, 10)
      assert length(messages) == 3

      # Verify order
      assert Enum.map(messages, & &1.seq) == [1, 2, 3]
      assert Enum.at(messages, 0).content["text"] == "msg1"
      assert Enum.at(messages, 1).content["text"] == "msg2"
      assert Enum.at(messages, 2).content["text"] == "msg3"
    end

    test "get_messages with after_seq filter" do
      session = create_test_session("alice", "bob")

      # Append 5 messages
      for seq <- 1..5 do
        :ok =
          API.append_message(
            session.id,
            seq,
            "alice",
            "bob",
            "text",
            %{"seq" => seq},
            %{}
          )
      end

      # Flush
      slot = :erlang.phash2(session.id, 64)
      wait_for_flush(slot)

      # Get messages after seq 2
      {:ok, messages} = API.get_messages(session.id, 2, 10)
      assert length(messages) == 3
      assert Enum.map(messages, & &1.seq) == [3, 4, 5]
    end

    test "get_messages respects limit" do
      session = create_test_session("alice", "bob")

      # Append 10 messages
      for seq <- 1..10 do
        :ok = API.append_message(session.id, seq, "alice", "bob", "text", %{}, %{})
      end

      # Flush
      slot = :erlang.phash2(session.id, 64)
      wait_for_flush(slot)

      # Get only 5 messages
      {:ok, messages} = API.get_messages(session.id, 0, 5)
      assert length(messages) == 5
      assert Enum.map(messages, & &1.seq) == [1, 2, 3, 4, 5]
    end
  end

  describe "session operations" do
    test "get_sessions_for_sender" do
      session1 = create_test_session("alice", "bob")
      session2 = create_test_session("alice", "charlie")
      _session3 = create_test_session("bob", "alice")

      {:ok, sessions} = API.get_sessions_for_user("alice")
      session_ids = Enum.map(sessions, & &1.id) |> Enum.sort()

      assert length(sessions) == 2
      assert session1.id in session_ids
      assert session2.id in session_ids
    end

    test "get_sessions_for_identity" do
      session1 = create_test_session("alice", "bob")
      session2 = create_test_session("charlie", "alice")
      _session3 = create_test_session("bob", "charlie")

      {:ok, sessions} = API.get_sessions_for_identity("alice")
      session_ids = Enum.map(sessions, & &1.id) |> Enum.sort()

      assert length(sessions) == 2
      assert session1.id in session_ids
      assert session2.id in session_ids
    end

    test "archive_session" do
      session = create_test_session("alice", "bob")
      assert session.status == "active"

      {:ok, archived} = API.archive_session(session.id)
      assert archived.status == "archived"

      # Archived sessions should not appear in sender's active sessions
      {:ok, sessions} = API.get_sessions_for_user("alice")
      assert Enum.all?(sessions, &(&1.status != "archived"))
    end
  end

  describe "cursor operations" do
    test "update_cursor" do
      session = create_test_session("alice", "bob")

      {:ok, cursor} = API.update_cursor(session.id, "alice", 5)
      assert cursor.session_id == session.id
      assert cursor.user_id == "alice"
      assert cursor.last_seq == 5

      # Updating again should upsert
      {:ok, cursor} = API.update_cursor(session.id, "alice", 10)
      assert cursor.last_seq == 10
    end
  end
end
