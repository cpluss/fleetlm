defmodule Fleetlm.Storage.SlotLogAdvancedTest do
  @moduledoc """
  Advanced test cases for slot log server covering:
  - Segment rotation and cleanup
  - Multi-segment operations
  - Data integrity (CRC validation)
  - Concurrency scenarios
  - Large-scale operations
  """

  use Fleetlm.TestCase
  use Bitwise

  import Ecto.Query

  alias Fleetlm.Storage.CommitLog
  alias Fleetlm.Storage.CommitLog.Cursor
  alias Fleetlm.Storage.SlotLogServer
  alias Fleetlm.Storage.Model.Message

  setup %{slot_log_dir: slot_log_dir} do
    slot = 100 + System.unique_integer([:positive])

    {:ok, pid} = Fleetlm.Storage.Supervisor.ensure_started(slot)

    on_exit(fn ->
      :ok = Fleetlm.Storage.Supervisor.flush_slot(slot)
      :ok = Fleetlm.Storage.Supervisor.stop_slot(slot)
    end)

    %{slot: slot, server_pid: pid, slot_log_dir: slot_log_dir}
  end

  describe "segment rotation" do
    test "rotates to new segment when size limit exceeded", %{
      slot: slot,
      slot_log_dir: slot_log_dir
    } do
      # Test rotation directly with CommitLog API (without SlotLogServer)
      :ok = Fleetlm.Storage.Supervisor.stop_slot(slot)

      session = create_test_session()

      # Start with 256 byte segment limit - this will force rotation on first write
      {:ok, log} = CommitLog.open(slot, segment_bytes: 256)

      # Write entries - first one fits in segment 0, second forces rotation to segment 1
      entry1 = build_entry(slot, session.id, 1)
      {:ok, log} = CommitLog.append(log, entry1)

      entry2 = build_entry(slot, session.id, 2)
      {:ok, log} = CommitLog.append(log, entry2)

      entry3 = build_entry(slot, session.id, 3)
      {:ok, log} = CommitLog.append(log, entry3)

      {:ok, log} = CommitLog.sync(log)
      :ok = CommitLog.close(log)

      # Check that multiple segment files exist
      files =
        File.ls!(slot_log_dir)
        |> Enum.filter(&String.contains?(&1, "slot_#{slot}_"))
        |> Enum.filter(&String.ends_with?(&1, ".wal"))

      assert length(files) >= 2, "Expected multiple segments, got: #{inspect(files)}"
    end

    test "drops old segments after successful flush", %{slot: slot, slot_log_dir: slot_log_dir} do
      # Test segment cleanup directly with CommitLog API
      session = create_test_session()

      # Create log with small segments
      {:ok, log} = CommitLog.open(slot, segment_bytes: 256)

      # Write entries to create multiple segments
      for seq <- 1..5 do
        entry = build_entry(slot, session.id, seq)
        {:ok, log_updated} = CommitLog.append(log, entry)
        log = log_updated
      end

      {:ok, log} = CommitLog.sync(log)

      files_before =
        File.ls!(slot_log_dir)
        |> Enum.filter(&String.contains?(&1, "slot_#{slot}_"))
        |> Enum.filter(&String.ends_with?(&1, ".wal"))

      assert length(files_before) >= 2,
             "Need multiple segments for test, got: #{inspect(files_before)}"

      tip = CommitLog.tip(log)

      # Drop all segments except the most recent (simulate a flush that completed)
      # Create a cursor at the start of the tip segment
      flush_cursor = %CommitLog.Cursor{segment: tip.segment, offset: 0}
      {:ok, log} = CommitLog.drop_completed_segments(log, flush_cursor)

      :ok = CommitLog.close(log)

      files_after =
        File.ls!(slot_log_dir)
        |> Enum.filter(&String.contains?(&1, "slot_#{slot}_"))
        |> Enum.filter(&String.ends_with?(&1, ".wal"))

      # Should have just the tip segment remaining
      # (All segments before the flush cursor are dropped)
      assert length(files_after) <= 1,
             "Expected at most 1 segment after cleanup, got: #{inspect(files_after)}"
    end
  end

  describe "multi-segment reads" do
    test "reads entries across multiple segments", %{slot: slot, slot_log_dir: slot_log_dir} do
      # Stop slot server to avoid file conflicts
      :ok = Fleetlm.Storage.Supervisor.stop_slot(slot)

      # Test multi-segment reads directly with CommitLog API
      session = create_test_session()

      {:ok, log} = CommitLog.open(slot, segment_bytes: 256)

      # Write entries across multiple segments
      entry_count = 10

      for seq <- 1..entry_count do
        entry = build_entry(slot, session.id, seq)
        {:ok, log_updated} = CommitLog.append(log, entry)
        log = log_updated
      end

      {:ok, log} = CommitLog.sync(log)

      # Verify multiple segments were created
      files =
        File.ls!(slot_log_dir)
        |> Enum.filter(&String.contains?(&1, "slot_#{slot}_"))
        |> Enum.filter(&String.ends_with?(&1, ".wal"))

      assert length(files) >= 2, "Test requires multiple segments, got: #{inspect(files)}"

      # Read all entries using fold - should work across segments
      start_cursor = %CommitLog.Cursor{segment: 0, offset: 0}
      tip_cursor = CommitLog.tip(log)

      {:ok, {_final_cursor, entries}} =
        CommitLog.fold(slot, start_cursor, tip_cursor, [], [], fn batch, acc ->
          {:cont, acc ++ batch}
        end)

      :ok = CommitLog.close(log)

      assert length(entries) == entry_count
      assert Enum.map(entries, & &1.seq) == Enum.to_list(1..entry_count)
    end

    test "snapshot works across multiple segments", %{slot: slot} do
      # This tests SlotLogServer reading across segments
      # Use a medium-sized batch to hopefully create multiple segments over time
      session = create_test_session()

      # Just write many entries - over time with default limits they may span segments
      for seq <- 1..50 do
        entry = build_entry(slot, session.id, seq)
        :ok = SlotLogServer.append(slot, entry)
      end

      {:ok, snapshot} = SlotLogServer.snapshot(slot)

      # Should get all entries regardless of segmentation
      assert length(snapshot.pending_entries) == 50
      assert Enum.map(snapshot.pending_entries, & &1.seq) == Enum.to_list(1..50)
    end
  end

  describe "data integrity during reads" do
    test "detects CRC mismatch during read and stops", %{slot: slot, slot_log_dir: slot_log_dir} do
      session = create_test_session()

      # Write some valid entries
      for seq <- 1..3 do
        entry = build_entry(slot, session.id, seq)
        :ok = SlotLogServer.append(slot, entry)
      end

      # Flush and stop to close file handles
      :ok = SlotLogServer.flush_now(slot)
      :ok = Fleetlm.Storage.Supervisor.stop_slot(slot)

      # Corrupt the WAL file by flipping bits in the middle
      wal_files =
        File.ls!(slot_log_dir)
        |> Enum.filter(&String.contains?(&1, "slot_#{slot}_"))
        |> Enum.filter(&String.ends_with?(&1, ".wal"))

      assert [wal_file | _] = wal_files

      wal_path = Path.join(slot_log_dir, wal_file)
      data = File.read!(wal_path)

      # Flip some bits in the middle to corrupt a frame (skip header)
      if byte_size(data) > 100 do
        <<before::binary-size(100), byte::8, rest::binary>> = data
        corrupted = <<before::binary, byte ^^^ 0xFF, rest::binary>>
        File.write!(wal_path, corrupted)

        # Restart - should repair and truncate
        {:ok, _pid} = Fleetlm.Storage.Supervisor.ensure_started(slot)

        # Should be able to read but won't get all entries due to truncation
        {:ok, entries} = SlotLogServer.read(slot, session.id, 0)

        # We should get fewer than 3 entries due to truncation
        assert length(entries) < 3
      end
    end
  end

  describe "concurrency" do
    test "handles appends during flush", %{slot: slot} do
      session = create_test_session()

      # Start writing entries
      for seq <- 1..5 do
        entry = build_entry(slot, session.id, seq)
        :ok = SlotLogServer.append(slot, entry)
      end

      # Request notification for next flush
      SlotLogServer.notify_next_flush(slot)

      # Trigger periodic flush (non-blocking)
      send(self(), :flush)
      Process.sleep(10)

      # Write more entries while flush might be running
      for seq <- 6..10 do
        entry = build_entry(slot, session.id, seq)
        :ok = SlotLogServer.append(slot, entry)
      end

      # Wait for flush
      assert_receive :flushed, 2_000

      # Force another flush to ensure all entries are persisted
      result = SlotLogServer.flush_now(slot)
      assert result in [:ok, :already_clean]

      # All entries should be in DB
      messages =
        Message
        |> where([m], m.session_id == ^session.id)
        |> Repo.all()

      assert length(messages) == 10
    end

    test "queues second flush_now while first is running", %{slot: slot} do
      session = create_test_session()

      # Create many entries to make flush take longer
      for seq <- 1..100 do
        entry = build_entry(slot, session.id, seq)
        :ok = SlotLogServer.append(slot, entry)
      end

      # Start two concurrent flush_now calls
      task1 = Task.async(fn -> SlotLogServer.flush_now(slot) end)
      Process.sleep(10)
      task2 = Task.async(fn -> SlotLogServer.flush_now(slot) end)

      # Both should succeed
      assert :ok = Task.await(task1, 10_000)
      result2 = Task.await(task2, 10_000)
      assert result2 in [:ok, :already_clean]
    end

    test "read works correctly during concurrent writes", %{slot: slot} do
      session = create_test_session()

      # Write some initial entries
      for seq <- 1..5 do
        entry = build_entry(slot, session.id, seq)
        :ok = SlotLogServer.append(slot, entry)
      end

      # Start concurrent operations
      writer_task =
        Task.async(fn ->
          for seq <- 6..10 do
            entry = build_entry(slot, session.id, seq)
            :ok = SlotLogServer.append(slot, entry)
            Process.sleep(10)
          end

          :ok
        end)

      reader_task =
        Task.async(fn ->
          for _ <- 1..5 do
            {:ok, _entries} = SlotLogServer.read(slot, session.id, 0)
            Process.sleep(15)
          end

          :ok
        end)

      # Both should complete successfully
      assert :ok = Task.await(writer_task, 5_000)
      assert :ok = Task.await(reader_task, 5_000)

      # Flush to database to verify all entries were written
      SlotLogServer.flush_now(slot)

      # Check all entries made it to the database
      count =
        Message
        |> where([m], m.session_id == ^session.id)
        |> Repo.aggregate(:count)

      assert count == 10
    end
  end

  describe "large scale operations" do
    test "handles batches exceeding PostgreSQL parameter limit", %{slot: slot} do
      session = create_test_session()

      # Create 6000 entries (exceeds 5000 batch limit)
      entry_count = 6000

      for seq <- 1..entry_count do
        entry = build_entry(slot, session.id, seq)
        :ok = SlotLogServer.append(slot, entry)

        # Periodic progress update
        if rem(seq, 1000) == 0, do: IO.puts("Written #{seq}/#{entry_count}")
      end

      # Flush should handle batching internally
      assert :ok = SlotLogServer.flush_now(slot)

      # All entries should be persisted
      count =
        Message
        |> where([m], m.session_id == ^session.id)
        |> Repo.aggregate(:count)

      assert count == entry_count
    end
  end

  describe "edge cases" do
    test "reading at exact tip returns empty list", %{slot: slot} do
      session = create_test_session()

      entry = build_entry(slot, session.id, 1)
      :ok = SlotLogServer.append(slot, entry)

      # Read at tip (after all entries)
      {:ok, entries} = SlotLogServer.read(slot, session.id, 1)
      assert entries == []
    end

    test "flush with no dirty data is idempotent", %{slot: slot} do
      # Multiple flushes of empty log
      assert :already_clean = SlotLogServer.flush_now(slot)
      assert :already_clean = SlotLogServer.flush_now(slot)
      assert :already_clean = SlotLogServer.flush_now(slot)
    end

    test "duplicate flush does not create duplicate DB entries", %{slot: slot} do
      session = create_test_session()

      entry = build_entry(slot, session.id, 1)
      :ok = SlotLogServer.append(slot, entry)

      # Flush twice
      assert :ok = SlotLogServer.flush_now(slot)
      assert :already_clean = SlotLogServer.flush_now(slot)

      # Should only have one entry in DB
      count =
        Message
        |> where([m], m.session_id == ^session.id)
        |> Repo.aggregate(:count)

      assert count == 1
    end

    test "handles reading from empty log", %{slot: slot} do
      session = create_test_session()

      {:ok, entries} = SlotLogServer.read(slot, session.id, 0)
      assert entries == []

      {:ok, snapshot} = SlotLogServer.snapshot(slot)
      assert snapshot.pending_entries == []
    end
  end
end
