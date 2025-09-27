defmodule Fleetlm.Runtime.Storage.EtsRingTest do
  use ExUnit.Case, async: true

  alias Fleetlm.Runtime.Storage.{EtsRing, Entry}
  alias Fleetlm.Conversation.ChatMessage

  describe "put/4" do
    test "stores entries per session and enforces ring limit" do
      table = EtsRing.new()
      on_exit(fn -> EtsRing.destroy(table) end)

      entry1 = build_entry("session-1", 1)
      entry2 = build_entry("session-1", 2)
      entry3 = build_entry("session-1", 3)

      assert [] == EtsRing.list(table, "session-1")

      assert [^entry1] = EtsRing.put(table, "session-1", entry1, 2)
      assert [^entry2, ^entry1] = EtsRing.put(table, "session-1", entry2, 2)

      assert [^entry3, ^entry2] = EtsRing.put(table, "session-1", entry3, 2)
    end
  end

  describe "list/2" do
    test "returns empty list for unknown session" do
      table = EtsRing.new()
      on_exit(fn -> EtsRing.destroy(table) end)

      assert [] == EtsRing.list(table, "missing")
    end
  end

  describe "destroy/1" do
    test "can be called multiple times without raising" do
      table = EtsRing.new()

      assert :ok == EtsRing.destroy(table)
      assert :ok == EtsRing.destroy(table)
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

    Entry.from_message(42, seq, "idem-#{seq}", message)
  end
end
