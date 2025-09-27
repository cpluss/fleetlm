defmodule Fleetlm.Runtime.Storage.IdempotencyCacheTest do
  use ExUnit.Case, async: true

  alias Fleetlm.Runtime.Storage.{IdempotencyCache, Entry}
  alias Fleetlm.Conversation.ChatMessage

  setup do
    table = IdempotencyCache.new()

    on_exit(fn -> IdempotencyCache.destroy(table) end)

    {:ok, table: table}
  end

  describe "put/4 and fetch/4" do
    test "returns hit when entry is present", %{table: table} do
      entry = build_entry("session", 1)

      :ok = IdempotencyCache.put(table, entry.session_id, "key", entry)
      assert {:hit, ^entry} = IdempotencyCache.fetch(table, entry.session_id, "key")
    end

    test "expires entries past ttl", %{table: table} do
      entry = build_entry("session", 1)

      :ok = IdempotencyCache.put(table, entry.session_id, "key", entry)

      Process.sleep(5)

      assert :miss = IdempotencyCache.fetch(table, entry.session_id, "key", ttl_ms: 1)
    end

    test "missing entries return miss", %{table: table} do
      assert :miss = IdempotencyCache.fetch(table, "session", "key")
    end
  end

  describe "destroy/1" do
    test "is safe to call multiple times", %{table: table} do
      assert :ok == IdempotencyCache.destroy(table)
      assert :ok == IdempotencyCache.destroy(table)
    end
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

    Entry.from_message(7, seq, "idem-#{seq}", message)
  end
end
