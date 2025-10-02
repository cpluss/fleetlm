defmodule FleetLM.Storage.SlotLogServerTest do
  use Fleetlm.TestCase

  import Ecto.Query

  setup %{slot_log_dir: slot_log_dir} do
    # Use a high, unique slot number to avoid production range (0-63)
    slot = 100 + System.unique_integer([:positive])

    {:ok, pid} = FleetLM.Storage.Supervisor.ensure_started(slot)

    on_exit(fn ->
      :ok = FleetLM.Storage.Supervisor.flush_slot(slot)
      :ok = FleetLM.Storage.Supervisor.stop_slot(slot)
    end)

    %{slot: slot, server_pid: pid, slot_log_dir: slot_log_dir}
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

      # Verify entries were persisted to database (for these specific sessions)
      messages =
        Message
        |> where([m], m.session_id in [^session1.id, ^session2.id])
        |> Repo.all()

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

    test "retains entries on disk after successful flush", %{slot: slot} do
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

      # Verify disk log still contains the flushed entry
      {:ok, entries_after} = DiskLog.read_all(log)
      assert Enum.map(entries_after, & &1.seq) == [1]
    end

    test "compacts disk log when retention limit is exceeded", %{slot: slot} do
      previous_max_bytes = Application.get_env(:fleetlm, :slot_log_max_bytes)
      previous_target = Application.get_env(:fleetlm, :slot_log_compact_target)

      # Restart the slot with a small retention window to exercise compaction.
      :ok = FleetLM.Storage.Supervisor.stop_slot(slot)

      session = create_test_session()

      entry_template =
        build_entry(slot, session.id, 1, content: %{"text" => String.duplicate("x", 64)})

      entry_size = :erlang.external_size(entry_template)
      max_bytes = entry_size * 2

      Application.put_env(:fleetlm, :slot_log_max_bytes, max_bytes)
      Application.put_env(:fleetlm, :slot_log_compact_target, 1.0)

      on_exit(fn ->
        maybe_restore_env(:slot_log_max_bytes, previous_max_bytes)
        maybe_restore_env(:slot_log_compact_target, previous_target)
      end)

      {:ok, _pid} = FleetLM.Storage.Supervisor.ensure_started(slot)

      entry1 = entry_template
      entry2 = build_entry(slot, session.id, 2, content: %{"text" => String.duplicate("y", 64)})
      entry3 = build_entry(slot, session.id, 3, content: %{"text" => String.duplicate("z", 64)})

      :ok = SlotLogServer.append(slot, entry1)
      :ok = SlotLogServer.append(slot, entry2)
      :ok = SlotLogServer.append(slot, entry3)

      assert :ok = SlotLogServer.flush_now(slot)

      {:ok, log} = SlotLogServer.get_log_handle(slot)
      {:ok, entries_after} = DiskLog.read_all(log)

      assert Enum.map(entries_after, & &1.seq) == [2, 3]

      # Appending a new entry should keep the two most recent flushed messages on disk
      # once the new entry has been persisted.
      entry4 = build_entry(slot, session.id, 4, content: %{"text" => String.duplicate("w", 64)})
      :ok = SlotLogServer.append(slot, entry4)
      assert :ok = SlotLogServer.flush_now(slot)

      {:ok, entries_final} = DiskLog.read_all(log)
      assert Enum.map(entries_final, & &1.seq) == [3, 4]
    end

    test "persists cursor to disk and restores after restart", %{
      slot: slot,
      slot_log_dir: slot_log_dir
    } do
      session = create_test_session()
      entry = build_entry(slot, session.id, 1)

      :ok = SlotLogServer.append(slot, entry)
      assert :ok = SlotLogServer.flush_now(slot)

      cursor_path = Path.join(slot_log_dir, "slot_#{slot}.cursor")
      assert File.exists?(cursor_path)
      assert {:ok, 1} = DiskLog.load_cursor(slot)

      :ok = FleetLM.Storage.Supervisor.stop_slot(slot)
      {:ok, _pid} = FleetLM.Storage.Supervisor.ensure_started(slot)

      wait_for_slot(slot)
      assert :already_clean = SlotLogServer.flush_now(slot)

      {:ok, log} = SlotLogServer.get_log_handle(slot)
      {:ok, entries} = DiskLog.read_all(log)
      assert Enum.map(entries, & &1.seq) == [1]
      assert {:ok, 1} = DiskLog.load_cursor(slot)
    end

    test "restores dirty cursor after crash", %{slot: slot, server_pid: server_pid} do
      session = create_test_session()

      entry1 = build_entry(slot, session.id, 1)
      entry2 = build_entry(slot, session.id, 2)

      :ok = SlotLogServer.append(slot, entry1)
      assert :ok = SlotLogServer.flush_now(slot)
      assert {:ok, 1} = DiskLog.load_cursor(slot)

      :ok = SlotLogServer.append(slot, entry2)

      ref = Process.monitor(server_pid)
      Process.exit(server_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^server_pid, :killed}, 1_000

      {:ok, _new_pid} = FleetLM.Storage.Supervisor.ensure_started(slot)
      wait_for_slot(slot, exclude: server_pid)

      assert :ok = SlotLogServer.flush_now(slot)

      messages =
        Message
        |> where([m], m.session_id == ^session.id)
        |> order_by([m], asc: m.seq)
        |> Repo.all()

      assert Enum.map(messages, & &1.seq) == [1, 2]
      assert {:ok, 2} = DiskLog.load_cursor(slot)
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
      slot = 200 + System.unique_integer([:positive])
      session = create_test_session()

      {:ok, _pid} = FleetLM.Storage.Supervisor.ensure_started(slot)

      entry = build_entry(slot, session.id, 1)
      SlotLogServer.append(slot, entry)

      # Stop the server via supervisor which triggers terminate/2
      :ok = FleetLM.Storage.Supervisor.stop_slot(slot)

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

  defp wait_for_slot(slot), do: wait_for_slot(slot, [])

  defp wait_for_slot(slot, opts) do
    exclude = Keyword.get(opts, :exclude)

    eventually(fn ->
      {:ok, _pid} = FleetLM.Storage.Supervisor.ensure_started(slot)
      assert [{pid, _}] = Registry.lookup(FleetLM.Storage.Registry, slot)
      assert Process.alive?(pid)

      if exclude do
        refute pid == exclude
      end
    end)
  end

  defp maybe_restore_env(key, nil), do: Application.delete_env(:fleetlm, key)
  defp maybe_restore_env(key, value), do: Application.put_env(:fleetlm, key, value)
end
