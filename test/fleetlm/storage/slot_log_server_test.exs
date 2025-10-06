defmodule Fleetlm.Storage.SlotLogServerTest do
  use Fleetlm.TestCase

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

  describe "append/2" do
    test "stores an entry in the commit log", %{slot: slot} do
      session = create_test_session()
      entry = build_entry(slot, session.id, 1)

      assert :ok = SlotLogServer.append(slot, entry)

      assert {:ok, %{pending_entries: [stored], flushed_cursor: %Cursor{offset: 0}}} =
               SlotLogServer.snapshot(slot)

      assert stored.session_id == session.id
      assert stored.seq == 1
    end

    test "preserves append order across sessions", %{slot: slot} do
      session1 = create_test_session("alice", "bob")
      session2 = create_test_session("charlie", "dave")

      entry1 = build_entry(slot, session1.id, 1)
      entry2 = build_entry(slot, session1.id, 2)
      entry3 = build_entry(slot, session2.id, 1)

      assert :ok = SlotLogServer.append(slot, entry1)
      assert :ok = SlotLogServer.append(slot, entry2)
      assert :ok = SlotLogServer.append(slot, entry3)

      assert {:ok, %{pending_entries: entries}} = SlotLogServer.snapshot(slot)

      assert Enum.map(entries, &{&1.session_id, &1.seq}) ==
               [{session1.id, 1}, {session1.id, 2}, {session2.id, 1}]
    end
  end

  describe "flush" do
    test "flushes to database on the periodic schedule", %{slot: slot} do
      session1 = create_test_session("alice", "bob")
      session2 = create_test_session("charlie", "dave")

      entry1 = build_entry(slot, session1.id, 1)
      entry2 = build_entry(slot, session1.id, 2)
      entry3 = build_entry(slot, session2.id, 1)

      SlotLogServer.notify_next_flush(slot)

      :ok = SlotLogServer.append(slot, entry1)
      :ok = SlotLogServer.append(slot, entry2)
      :ok = SlotLogServer.append(slot, entry3)

      assert_receive :flushed, 1_000

      messages =
        Message
        |> where([m], m.session_id in [^session1.id, ^session2.id])
        |> Repo.all()

      # Check that all three entries made it to the database (order may vary due to same timestamp)
      assert length(messages) == 3

      message_tuples = Enum.map(messages, &{&1.session_id, &1.seq}) |> MapSet.new()

      assert MapSet.equal?(
               message_tuples,
               MapSet.new([{session1.id, 1}, {session1.id, 2}, {session2.id, 1}])
             )

      assert {:ok, %{pending_entries: []}} = SlotLogServer.snapshot(slot)
    end

    test "flush_now persists pending entries and clears the WAL", %{slot: slot} do
      session = create_test_session()
      entry = build_entry(slot, session.id, 1)

      :ok = SlotLogServer.append(slot, entry)
      assert {:ok, %{pending_entries: [_]}} = SlotLogServer.snapshot(slot)

      assert :ok = SlotLogServer.flush_now(slot)

      messages =
        Message
        |> where([m], m.session_id == ^session.id)
        |> Repo.all()

      assert Enum.map(messages, & &1.seq) == [1]
      assert {:ok, %{pending_entries: []}} = SlotLogServer.snapshot(slot)
    end

    test "flush_now is idempotent when already clean", %{slot: slot} do
      assert :already_clean = SlotLogServer.flush_now(slot)
    end
  end

  describe "cursor persistence" do
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
      assert {:ok, %Cursor{} = cursor} = CommitLog.load_cursor(slot)

      :ok = Fleetlm.Storage.Supervisor.stop_slot(slot)
      {:ok, _pid} = Fleetlm.Storage.Supervisor.ensure_started(slot)
      wait_for_slot(slot)

      assert :already_clean = SlotLogServer.flush_now(slot)
      assert {:ok, %Cursor{} = reloaded} = CommitLog.load_cursor(slot)
      assert reloaded == cursor
    end

    test "recovers dirty cursor after crash", %{slot: slot, server_pid: server_pid} do
      session = create_test_session()

      entry1 = build_entry(slot, session.id, 1)
      entry2 = build_entry(slot, session.id, 2)

      :ok = SlotLogServer.append(slot, entry1)
      assert :ok = SlotLogServer.flush_now(slot)
      assert {:ok, %Cursor{} = first_cursor} = CommitLog.load_cursor(slot)

      :ok = SlotLogServer.append(slot, entry2)

      ref = Process.monitor(server_pid)
      Process.exit(server_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^server_pid, :killed}, 1_000

      {:ok, _new_pid} = Fleetlm.Storage.Supervisor.ensure_started(slot)
      wait_for_slot(slot, exclude: server_pid)

      assert :ok = SlotLogServer.flush_now(slot)

      messages =
        Message
        |> where([m], m.session_id == ^session.id)
        |> order_by([m], asc: m.seq)
        |> Repo.all()

      assert Enum.map(messages, & &1.seq) == [1, 2]

      assert {:ok, %Cursor{} = cursor} = CommitLog.load_cursor(slot)
      assert cursor.segment >= first_cursor.segment
      assert cursor.offset >= first_cursor.offset
    end
  end

  describe "read/3" do
    test "returns in-flight entries for a session", %{slot: slot} do
      session = create_test_session()

      entry1 = build_entry(slot, session.id, 1)
      entry2 = build_entry(slot, session.id, 2)

      :ok = SlotLogServer.append(slot, entry1)
      :ok = SlotLogServer.append(slot, entry2)

      assert {:ok, [^entry1, ^entry2]} = SlotLogServer.read(slot, session.id, 0)
      assert {:ok, [^entry2]} = SlotLogServer.read(slot, session.id, 1)
    end

    test "ignores entries for other sessions", %{slot: slot} do
      session1 = create_test_session("alice", "bob")
      session2 = create_test_session("carol", "dave")

      entry1 = build_entry(slot, session1.id, 1)
      entry2 = build_entry(slot, session2.id, 1)

      :ok = SlotLogServer.append(slot, entry1)
      :ok = SlotLogServer.append(slot, entry2)

      assert {:ok, [^entry1]} = SlotLogServer.read(slot, session1.id, 0)
    end
  end

  defp wait_for_slot(slot, opts \\ []) do
    exclude = Keyword.get(opts, :exclude, nil)
    # Use longer timeout to allow for slow GenServer initialization
    timeout = Keyword.get(opts, :timeout, 2_000)

    eventually(
      fn ->
      try do
        case Registry.lookup(Fleetlm.Storage.Registry, slot) do
          [{pid, _}] ->
            cond do
              exclude != nil and pid == exclude ->
                raise "Old slot server still running"

              exclude != nil and not Process.alive?(exclude) ->
                # Old process is dead, verify new server is responsive
                # Use short timeout to allow eventually to retry quickly
                via = {:via, Registry, {Fleetlm.Storage.Registry, slot}}

                case GenServer.call(via, :snapshot, 100) do
                  {:ok, _} -> :ok
                  _ -> raise "Slot server not ready yet"
                end

              exclude == nil ->
                # No exclude filter, just verify server is responsive
                # Use short timeout to allow eventually to retry quickly
                via = {:via, Registry, {Fleetlm.Storage.Registry, slot}}

                case GenServer.call(via, :snapshot, 100) do
                  {:ok, _} -> :ok
                  _ -> raise "Slot server not ready yet"
                end

              true ->
                raise "Waiting for old process to exit"
            end

          [] ->
            raise "Slot server not started yet"
        end
      catch
        # Catch exit from GenServer.call timeout and convert to raise for eventually
        :exit, {:timeout, _} -> raise "Slot server call timeout"
      end
    end,
      timeout: timeout
    )
  end
end
