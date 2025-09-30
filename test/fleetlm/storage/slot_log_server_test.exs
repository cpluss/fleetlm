defmodule FleetLM.Storage.SlotLogServerTest do
  use Fleetlm.StorageCase, async: false

  setup do
    # Use a high slot number to avoid conflicts with production SlotLogServers
    # and start our own test-specific SlotLogServer
    slot = 100

    case start_supervised({SlotLogServer, slot}) do
      {:ok, pid} -> %{slot: slot, server_pid: pid}
      {:error, {:already_started, pid}} -> %{slot: slot, server_pid: pid}
    end
  end

  describe "append/2" do
    test "appends an entry to the disk log", %{slot: slot} do
      session = create_test_session()
      entry = build_entry(slot, session.id, 1)
      assert :ok = SlotLogServer.append(slot, entry)

      {:ok, log} = SlotLogServer.get_log_handle(slot)
      {:ok, entries} = DiskLog.read_all(log)
      assert length(entries) == 1
      assert hd(entries).session_id == session.id
      assert hd(entries).seq == 1
    end

    test "handles multiple appends", %{slot: slot} do
      session1 = create_test_session("alice", "bob")
      session2 = create_test_session("charlie", "dave")

      entry1 = build_entry(slot, session1.id, 1)
      entry2 = build_entry(slot, session1.id, 2)
      entry3 = build_entry(slot, session2.id, 1)

      assert :ok = SlotLogServer.append(slot, entry1)
      assert :ok = SlotLogServer.append(slot, entry2)
      assert :ok = SlotLogServer.append(slot, entry3)

      {:ok, log} = SlotLogServer.get_log_handle(slot)
      {:ok, entries} = DiskLog.read_all(log)
      assert length(entries) == 3
      assert match?([^entry1, ^entry2, ^entry3], entries)
    end
  end

  describe "flush to database" do
    test "flushes entries to database on schedule", %{slot: slot} do
      session1 = create_test_session("alice", "bob")
      session2 = create_test_session("charlie", "dave")

      entry1 = build_entry(slot, session1.id, 1)
      entry2 = build_entry(slot, session1.id, 2)
      entry3 = build_entry(slot, session2.id, 1)

      SlotLogServer.notify_next_flush(slot)
      assert :ok = SlotLogServer.append(slot, entry1)
      assert :ok = SlotLogServer.append(slot, entry2)
      assert :ok = SlotLogServer.append(slot, entry3)

      receive do
        :flushed -> :ok
      after
        1000 -> raise "Timeout waiting for flush"
      end

      # Verify entries were persisted to database
      messages = Repo.all(Message)
      assert length(messages) == 3

      # Compare structs ignoring __meta__ (which differs between :built and :loaded)
      expected =
        [Entry.to_message(entry1), Entry.to_message(entry2), Entry.to_message(entry3)]
        |> Enum.map(&Map.drop(&1, [:__meta__, :__struct__]))

      actual =
        messages
        |> Enum.map(&Map.drop(&1, [:__meta__, :__struct__]))

      assert expected == actual
    end

    test "truncates disk log after successful flush", %{slot: slot} do
      session = create_test_session()
      entry = build_entry(slot, session.id, 1)
      SlotLogServer.append(slot, entry)

      SlotLogServer.notify_next_flush(slot)

      # Verify entry is in disk log
      {:ok, log} = SlotLogServer.get_log_handle(slot)
      {:ok, entries_before} = DiskLog.read_all(log)
      assert length(entries_before) == 1

      receive do
        :flushed -> :ok
      after
        1000 -> raise "Timeout waiting for flush"
      end

      # Verify disk log was truncated
      {:ok, entries_after} = DiskLog.read_all(log)
      assert entries_after == []
    end

    test "handles multiple sessions in one flush", %{slot: slot} do
      session1 = create_test_session("alice", "bob")
      session2 = create_test_session("charlie", "dave")

      entry1 = build_entry(slot, session1.id, 1)
      entry2 = build_entry(slot, session2.id, 1)

      SlotLogServer.append(slot, entry1)
      SlotLogServer.append(slot, entry2)
      SlotLogServer.notify_next_flush(slot)

      receive do
        :flushed -> :ok
      after
        1000 -> raise "Timeout waiting for flush"
      end

      # Verify both sessions were persisted
      messages = Repo.all(Message)
      session_ids = Enum.map(messages, & &1.session_id)

      assert session1.id in session_ids
      assert session2.id in session_ids
    end
  end

  describe "terminate/2" do
    test "flushes dirty data on shutdown" do
      slot = 99
      session = create_test_session()

      # Start server manually so we can stop it
      {:ok, pid} = SlotLogServer.start_link(slot)
      Process.unlink(pid)

      entry = build_entry(slot, session.id, 1)
      SlotLogServer.append(slot, entry)

      # Stop the server and wait for it to complete termination
      # The terminate callback runs synchronously during shutdown
      :ok = GenServer.stop(pid, :shutdown)

      # Verify message was still persisted during shutdown
      messages = Repo.all(Message)

      expected =
        [Entry.to_message(entry)]
        |> Enum.map(&Map.drop(&1, [:__meta__, :__struct__]))

      actual =
        messages
        |> Enum.map(&Map.drop(&1, [:__meta__, :__struct__]))

      assert expected == actual
    end
  end

end
