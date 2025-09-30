defmodule FleetLM.Storage.SlotLogServerTest do
  # use Fleetlm.DataCase, async: false
  use ExUnit.Case, async: false

  alias FleetLM.Storage.{SlotLogServer, Entry, DiskLog}
  alias FleetLM.Storage.Model.Message
  alias Fleetlm.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Fleetlm.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Fleetlm.Repo, {:shared, self()})

    # Start a SlotLogServer for slot 0
    slot = 0
    {:ok, pid} = start_supervised({SlotLogServer, slot})

    # Cleanup: delete disk log file after test to ensure isolation
    on_exit(fn ->
      # After stop_supervised, the disk log is closed, so we can delete the file
      base_dir = Application.get_env(:fleetlm, :slot_log_dir, Application.app_dir(:fleetlm, "priv/storage/slot_logs"))
      disk_log_path = Path.join(base_dir, "slot_#{slot}.log")
      File.rm(disk_log_path)
    end)

    %{slot: slot, server_pid: pid}
  end

  describe "append/2" do
    test "appends an entry to the disk log", %{slot: slot} do
      entry = build_entry(slot, "session-1", 1)
      assert :ok = SlotLogServer.append(slot, entry)

      {:ok, log} = SlotLogServer.get_log_handle(slot)
      {:ok, entries} = DiskLog.read_all(log)
      assert length(entries) == 1
      assert hd(entries).session_id == "session-1"
      assert hd(entries).seq == 1
    end

    test "handles multiple appends", %{slot: slot} do
      entry1 = build_entry(slot, "session-1", 1)
      entry2 = build_entry(slot, "session-1", 2)
      entry3 = build_entry(slot, "session-2", 1)

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
      session1 = "session-#{System.unique_integer([:positive])}"
      session2 = "session-#{System.unique_integer([:positive])}"

      create_test_session(session1)
      create_test_session(session2)

      entry1 = build_entry(slot, session1, 1)
      entry2 = build_entry(slot, session1, 2)
      entry3 = build_entry(slot, session2, 1)

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
      expected = [Entry.to_message(entry1), Entry.to_message(entry2), Entry.to_message(entry3)]
      |> Enum.map(&Map.drop(&1, [:__meta__, :__struct__]))
      actual = messages
      |> Enum.map(&Map.drop(&1, [:__meta__, :__struct__]))

      assert expected == actual
    end

    test "truncates disk log after successful flush", %{slot: slot} do
      session_id = "session-#{System.unique_integer([:positive])}"
      create_test_session(session_id)

      entry = build_entry(slot, session_id, 1)
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
      session1 = "session-#{System.unique_integer([:positive])}"
      session2 = "session-#{System.unique_integer([:positive])}"

      create_test_session(session1)
      create_test_session(session2)

      entry1 = build_entry(slot, session1, 1)
      entry2 = build_entry(slot, session2, 1)

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

      assert session1 in session_ids
      assert session2 in session_ids
    end
  end

  describe "terminate/2" do
    test "flushes dirty data on shutdown" do
      slot = 99
      session_id = "session-#{System.unique_integer([:positive])}"

      create_test_session(session_id)

      # Start server manually so we can stop it
      {:ok, pid} = SlotLogServer.start_link(slot)
      Process.unlink(pid)

      entry = build_entry(slot, session_id, 1)
      SlotLogServer.append(slot, entry)

      # Stop the server and wait for it to complete termination
      # The terminate callback runs synchronously during shutdown
      :ok = GenServer.stop(pid, :shutdown)

      # Verify message was still persisted during shutdown
      messages = Repo.all(Message)
      expected = [Entry.to_message(entry)]
        |> Enum.map(&Map.drop(&1, [:__meta__, :__struct__]))
      actual = messages
        |> Enum.map(&Map.drop(&1, [:__meta__, :__struct__]))

      assert expected == actual
    end
  end

  defp build_entry(slot, session_id, seq) do
    message_id = Ulid.generate()
    build_entry_with_id(slot, session_id, seq, message_id)
  end

  defp build_entry_with_id(slot, session_id, seq, message_id) do
    message = %Message{
      id: message_id,
      session_id: session_id,
      sender_id: "sender-#{seq}",
      recipient_id: "recipient-#{seq}",
      seq: seq,
      kind: "text",
      content: %{"text" => "message #{seq}"},
      metadata: %{},
      shard_key: slot,
      inserted_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    }

    Entry.from_message(slot, seq, "idem-#{seq}", message)
  end

  defp create_test_session(session_id) do
    # Calculate shard_key the same way the API does
    num_slots = Application.get_env(:fleetlm, :num_storage_slots, 64)
    shard_key = :erlang.phash2(session_id, num_slots)

    Repo.insert!(%FleetLM.Storage.Model.Session{
      id: session_id,
      sender_id: "test-sender",
      recipient_id: "test-recipient",
      status: "active",
      metadata: %{},
      shard_key: shard_key
    })
  end
end
