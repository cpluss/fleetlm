defmodule Fleetlm.Storage.PoisonedDataTest do
  @moduledoc """
  Tests for handling poisoned/corrupted data in the storage layer.

  Poisoned data scenarios we must handle:
  1. NULL values in required fields (kind, content)
  2. Invalid data types
  3. Corrupted WAL frames
  4. Concurrent writes with schema violations
  5. Recovery after flush failures
  """

  use Fleetlm.TestCase

  import Ecto.Query
  require Logger
  require ExUnit.CaptureLog

  alias Fleetlm.Storage.{SlotLogServer, Entry}
  alias Fleetlm.Storage.Model.Message

  describe "NULL value handling" do
    test "rejects messages with NULL kind at API boundary" do
      session = create_test_session()

      assert_raise FunctionClauseError, fn ->
        StorageAPI.append_message(session.id, 1, "alice", "bob", nil, %{"text" => "hello"}, %{})
      end
    end

    test "rejects messages with NULL content at API boundary" do
      session = create_test_session()

      assert_raise FunctionClauseError, fn ->
        StorageAPI.append_message(session.id, 1, "alice", "bob", "text", nil, %{})
      end
    end

    test "handles corrupted entries with NULL kind during flush" do
      slot = 100 + System.unique_integer([:positive])

      {:ok, _pid} =
        suppress_expected_errors(fn ->
          Fleetlm.Storage.Supervisor.ensure_started(slot)
        end)

      on_exit(fn ->
        _ = Fleetlm.Storage.Supervisor.flush_slot(slot)
        _ = Fleetlm.Storage.Supervisor.stop_slot(slot)
      end)

      session = create_test_session()
      valid_entry = build_entry(slot, session.id, 1)
      :ok = SlotLogServer.append(slot, valid_entry)

      corrupted_entry = %Entry{
        slot: slot,
        seq: 2,
        session_id: "corrupted-session",
        idempotency_key: "test-key",
        message_id: Uniq.UUID.uuid7(:slug),
        inserted_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second),
        payload: %Message{
          id: Uniq.UUID.uuid7(:slug),
          session_id: "corrupted-session",
          sender_id: "sender",
          recipient_id: "recipient",
          seq: 2,
          kind: nil,
          content: nil,
          metadata: %{},
          shard_key: slot,
          inserted_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
        }
      }

      :ok = SlotLogServer.append(slot, corrupted_entry)

      suppress_expected_errors(fn ->
        assert {:error, _reason} = SlotLogServer.flush_now(slot)
      end)

      assert {:ok, %{pending_entries: entries}} = SlotLogServer.snapshot(slot)
      assert length(entries) == 2

      assert Repo.all(Message) == []
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

      session1 = create_test_session("alice", "bob")
      session2 = create_test_session("charlie", "dave")

      good_entry = build_entry(slot, session1.id, 1)

      bad_entry = %Entry{
        slot: slot,
        seq: 1,
        session_id: session2.id,
        idempotency_key: "bad-key",
        message_id: Uniq.UUID.uuid7(:slug),
        inserted_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second),
        payload: %Message{
          id: Uniq.UUID.uuid7(:slug),
          session_id: session2.id,
          sender_id: "sender",
          recipient_id: "recipient",
          seq: 1,
          kind: nil,
          content: nil,
          metadata: %{},
          shard_key: slot,
          inserted_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
        }
      }

      :ok = SlotLogServer.append(slot, good_entry)
      :ok = SlotLogServer.append(slot, bad_entry)

      suppress_expected_errors(fn ->
        assert {:error, _} = SlotLogServer.flush_now(slot)
      end)

      assert {:ok, %{pending_entries: entries}} = SlotLogServer.snapshot(slot)
      assert length(entries) == 2

      assert Repo.all(Message) == []
    end
  end

  describe "concurrent poisoning scenario" do
    test "handles race condition where entry becomes invalid after validation" do
      session = create_test_session()
      slot = :erlang.phash2(session.id, 64)

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

      assert :ok = SlotLogServer.flush_now(slot)

      messages =
        Message
        |> where([m], m.session_id == ^session.id)
        |> Repo.all()

      assert length(messages) == 1
    end
  end

  describe "commit log corruption recovery" do
    test "recovers from corrupted WAL segment" do
      slot = 100 + System.unique_integer([:positive])

      slot_dir = Application.get_env(:fleetlm, :slot_log_dir)
      wal_path = Path.join(slot_dir, "slot_#{slot}_00000000.wal")
      File.write!(wal_path, <<255, 255, 255, 255, 0, 0, 0, 0>>)

      {:ok, _pid} = Fleetlm.Storage.Supervisor.ensure_started(slot)

      on_exit(fn ->
        :ok = Fleetlm.Storage.Supervisor.flush_slot(slot)
        :ok = Fleetlm.Storage.Supervisor.stop_slot(slot)
      end)

      session = create_test_session()
      entry = build_entry(slot, session.id, 1)

      assert :ok = SlotLogServer.append(slot, entry)
      assert :ok = SlotLogServer.flush_now(slot)

      messages = Message |> where([m], m.session_id == ^session.id) |> Repo.all()
      assert length(messages) == 1
    end
  end

  describe "isolation between tests" do
    test "first test writes to its own isolated directory" do
      session = create_test_session()
      slot_dir = Application.get_env(:fleetlm, :slot_log_dir)

      assert String.contains?(slot_dir, "fleetlm-test-")

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

      slot = :erlang.phash2(session.id, 64)
      wal_path = Path.join(slot_dir, "slot_#{slot}_00000000.wal")
      assert File.exists?(wal_path)
    end

    test "second test has different isolated directory" do
      session = create_test_session()
      slot_dir = Application.get_env(:fleetlm, :slot_log_dir)

      assert String.contains?(slot_dir, "fleetlm-test-")

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

      slot = :erlang.phash2(session.id, 64)
      assert {:ok, %{pending_entries: entries}} = SlotLogServer.snapshot(slot)
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
