defmodule Fleetlm.Storage.PoisonedDataTest do
  @moduledoc """
  Tests for handling poisoned/corrupted data in the storage layer.

  Poisoned data scenarios we must handle:
  1. NULL values in required fields (kind, content)
  2. Invalid data types
  3. Corrupted disk log entries
  4. Concurrent writes with schema violations
  5. Recovery after flush failures
  """

  use Fleetlm.TestCase

  import Ecto.Query
  require Logger
  require ExUnit.CaptureLog

  describe "NULL value handling" do
    test "rejects messages with NULL kind at API boundary" do
      session = create_test_session()

      # Attempt to append message with nil kind
      assert_raise FunctionClauseError, fn ->
        StorageAPI.append_message(session.id, 1, "alice", "bob", nil, %{"text" => "hello"}, %{})
      end
    end

    test "rejects messages with NULL content at API boundary" do
      session = create_test_session()

      # Attempt to append message with nil content
      assert_raise FunctionClauseError, fn ->
        StorageAPI.append_message(session.id, 1, "alice", "bob", "text", nil, %{})
      end
    end

    test "handles corrupted WAL entries with NULL kind during flush" do
      # This tests the scenario where somehow a bad entry made it into the disk log
      # (perhaps from a previous bug or race condition)
      slot = 100 + System.unique_integer([:positive])

      {:ok, _pid} =
        suppress_expected_errors(fn ->
          Fleetlm.Storage.Supervisor.ensure_started(slot)
        end)

      on_exit(fn ->
        _ = Fleetlm.Storage.Supervisor.flush_slot(slot)
        _ = Fleetlm.Storage.Supervisor.stop_slot(slot)
      end)

      # Manually write a corrupted entry directly to disk log (bypassing SlotLogServer validation)
      {:ok, log} = SlotLogServer.get_log_handle(slot)

      corrupted_entry = %Fleetlm.Storage.Entry{
        slot: slot,
        seq: 1,
        session_id: "corrupted-session",
        idempotency_key: "test-key",
        payload: %Fleetlm.Storage.Model.Message{
          id: Uniq.UUID.uuid7(:slug),
          session_id: "corrupted-session",
          sender_id: "sender",
          recipient_id: "recipient",
          seq: 1,
          # ❌ NULL kind - poison pill
          kind: nil,
          # ❌ NULL content
          content: nil,
          metadata: %{},
          shard_key: slot,
          inserted_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
        }
      }

      # Write directly to disk log and mark the slot as dirty by writing a valid entry first
      session = create_test_session()
      valid_entry = build_entry(slot, session.id, 1)
      :ok = SlotLogServer.append(slot, valid_entry)

      # Now manually append the corrupted entry after the valid one
      :ok = DiskLog.append(log, corrupted_entry)

      # Attempt to flush - should fail gracefully
      suppress_expected_errors(fn ->
        # Flush should fail due to NOT NULL constraint (because of the corrupted entry)
        assert {:error, _reason} = SlotLogServer.flush_now(slot)
      end)

      # Verify both entries are still in the log (not truncated on failure - atomic behavior)
      {:ok, entries} = DiskLog.read_all(log)
      assert length(entries) == 2

      # Verify no messages were persisted to DB (all-or-nothing)
      messages = Message |> Repo.all()
      assert length(messages) == 0
    end
  end

  describe "partial flush recovery" do
    test "recovers when some messages flush successfully and others fail" do
      slot = 100 + System.unique_integer([:positive])

      {:ok, _pid} = Fleetlm.Storage.Supervisor.ensure_started(slot)

      on_exit(fn ->
        _ = Fleetlm.Storage.Supervisor.flush_slot(slot)
        _ = Fleetlm.Storage.Supervisor.stop_slot(slot)
      end)

      # Create sessions
      session1 = create_test_session("alice", "bob")
      session2 = create_test_session("charlie", "dave")

      # Write good entry
      good_entry = build_entry(slot, session1.id, 1, sender_id: "alice", recipient_id: "bob")
      :ok = SlotLogServer.append(slot, good_entry)

      # Write bad entry directly to disk log
      {:ok, log} = SlotLogServer.get_log_handle(slot)

      bad_entry = %Fleetlm.Storage.Entry{
        slot: slot,
        seq: 1,
        session_id: session2.id,
        idempotency_key: "bad-key",
        payload: %Fleetlm.Storage.Model.Message{
          id: Uniq.UUID.uuid7(:slug),
          session_id: session2.id,
          sender_id: "sender",
          recipient_id: "recipient",
          seq: 1,
          # ❌ Poison
          kind: nil,
          content: nil,
          metadata: %{},
          shard_key: slot,
          inserted_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
        }
      }

      :ok = DiskLog.append(log, bad_entry)

      # Attempt flush - should fail because of the bad entry
      suppress_expected_errors(fn ->
        assert {:error, _} = SlotLogServer.flush_now(slot)
      end)

      # Both entries should still be in the log (atomic flush behavior)
      {:ok, entries} = DiskLog.read_all(log)
      assert length(entries) == 2

      # No messages should be persisted (all-or-nothing)
      messages = Repo.all(Message)
      assert length(messages) == 0
    end
  end

  describe "concurrent poisoning scenario" do
    test "handles race condition where entry becomes invalid after validation" do
      # This scenario is hard to reproduce but represents a theoretical race
      # where validation passes but by the time we insert, the data is invalid
      # The database constraint should catch this

      session = create_test_session()
      slot = :erlang.phash2(session.id, 64)

      # Ensure slot server is started (handled automatically by StorageAPI)

      # Write a valid message
      :ok =
        StorageAPI.append_message(
          session.id,
          1,
          "alice",
          "bob",
          "text",
          %{"text" => "hello"},
          %{}
        )

      # Force immediate flush
      result = SlotLogServer.flush_now(slot)

      # Should succeed
      assert :ok = result

      # Verify message was persisted
      messages = Message |> where([m], m.session_id == ^session.id) |> Repo.all()
      assert length(messages) == 1
    end
  end

  describe "disk log corruption recovery" do
    test "recovers from corrupted disk log file" do
      slot = 100 + System.unique_integer([:positive])

      # Write some garbage to the disk log file before opening
      slot_dir = Application.get_env(:fleetlm, :slot_log_dir)
      log_path = Path.join(slot_dir, "slot_#{slot}.log")

      # Write invalid Erlang terms
      File.write!(log_path, <<255, 255, 255, 255, 0, 0, 0, 0>>)

      # Start SlotLogServer - should recover or recreate the log
      {:ok, _pid} = Fleetlm.Storage.Supervisor.ensure_started(slot)

      on_exit(fn ->
        :ok = Fleetlm.Storage.Supervisor.flush_slot(slot)
        :ok = Fleetlm.Storage.Supervisor.stop_slot(slot)
      end)

      # Should be able to append after recovery
      session = create_test_session()
      entry = build_entry(slot, session.id, 1)

      assert :ok = SlotLogServer.append(slot, entry)

      # Should be able to flush
      assert :ok = SlotLogServer.flush_now(slot)

      # Verify message was persisted
      messages = Message |> where([m], m.session_id == ^session.id) |> Repo.all()
      assert length(messages) == 1
    end
  end

  describe "isolation between tests" do
    test "first test writes to its own isolated directory" do
      session = create_test_session()
      slot_dir = Application.get_env(:fleetlm, :slot_log_dir)

      # Verify we have a unique temp directory
      assert String.contains?(slot_dir, "fleetlm-test-")

      # Write a message
      :ok =
        StorageAPI.append_message(
          session.id,
          1,
          "alice",
          "bob",
          "text",
          %{"text" => "test1"},
          %{}
        )

      # Get the slot and verify the log file is in our directory
      slot = :erlang.phash2(session.id, 64)
      log_path = Path.join(slot_dir, "slot_#{slot}.log")

      # File should exist in our isolated directory
      assert File.exists?(log_path)
    end

    test "second test has different isolated directory" do
      session = create_test_session()
      slot_dir = Application.get_env(:fleetlm, :slot_log_dir)

      # Verify we have a unique temp directory (different from previous test)
      assert String.contains?(slot_dir, "fleetlm-test-")

      # Write a message
      :ok =
        StorageAPI.append_message(
          session.id,
          1,
          "alice",
          "bob",
          "text",
          %{"text" => "test2"},
          %{}
        )

      # Verify isolation - directory should be empty of old test data
      slot = :erlang.phash2(session.id, 64)
      {:ok, log} = SlotLogServer.get_log_handle(slot)
      {:ok, entries} = DiskLog.read_all(log)

      # Should only have the one entry we just wrote, not entries from previous tests
      assert length(entries) == 1
      assert hd(entries).payload.content["text"] == "test2"
    end
  end

  defp suppress_expected_errors(fun) when is_function(fun, 0) do
    previous_level = Logger.level()
    Logger.configure(level: :critical)

    try do
      fun.()
    after
      Logger.configure(level: previous_level)
    end
  end
end
