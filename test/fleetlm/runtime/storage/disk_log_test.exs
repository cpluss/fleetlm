defmodule Fleetlm.Runtime.Storage.DiskLogTest do
  use ExUnit.Case

  alias Fleetlm.Runtime.Storage.{DiskLog, Entry}
  alias Fleetlm.Conversation.ChatMessage

  describe "open/2 and append/2" do
    test "persists entries to disk" do
      dir = tmp_dir()
      on_exit(fn -> cleanup_tmp(dir) end)
      {:ok, handle} = DiskLog.open(5, dir: dir, name: {:disk_log_test, 5})

      entry = build_entry("session-1", 1)

      assert {:ok, duration_us} = DiskLog.append(handle, entry)
      assert is_integer(duration_us) and duration_us >= 0

      # Verify the entry was actually persisted by reading it back
      assert {:ok, [read_entry]} = DiskLog.read_all(handle)
      assert read_entry.slot == entry.slot
      assert read_entry.session_id == entry.session_id
      assert read_entry.seq == entry.seq
      assert read_entry.message_id == entry.message_id
      assert read_entry.idempotency_key == entry.idempotency_key
      assert read_entry.payload.id == entry.payload.id
      assert read_entry.payload.content == entry.payload.content

      DiskLog.close(handle)

      # Verify file exists and has content
      assert File.stat!(Path.join(dir, "slot_5.log")).size > 0
    end
  end

  describe "close/1" do
    test "can be called on already closed handle" do
      dir = tmp_dir()
      on_exit(fn -> cleanup_tmp(dir) end)
      {:ok, handle} = DiskLog.open(8, dir: dir, name: {:disk_log_test, 8})

      assert :ok == DiskLog.close(handle)
      assert :ok == DiskLog.close(handle)
    end
  end

  defp tmp_dir do
    unique = System.unique_integer([:positive])
    dir = Path.join(System.tmp_dir!(), "fleetlm-disk-log-test-#{unique}")
    File.mkdir_p!(dir)
    dir
  end

  defp cleanup_tmp(dir) do
    File.rm_rf(dir)
  end

  defp build_entry(session_id, seq) do
    message =
      struct(ChatMessage, %{
        id: "msg-#{seq}",
        session_id: session_id,
        sender_id: "sender",
        kind: "text",
        content: %{text: "hello"},
        metadata: %{},
        shard_key: 1,
        inserted_at: NaiveDateTime.utc_now()
      })

    Entry.from_message(5, seq, "idem-#{seq}", message)
  end
end
