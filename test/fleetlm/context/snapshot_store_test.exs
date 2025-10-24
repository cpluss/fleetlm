defmodule Fleetlm.Context.SnapshotStoreTest do
  use Fleetlm.TestCase

  alias Fleetlm.Context.{Snapshot, SnapshotStore}

  test "persist and load snapshot" do
    session_id = "snapshot-test"

    snapshot = %Snapshot{
      strategy_id: "last_n",
      pending_messages: [],
      summary_messages: [],
      token_count: 0,
      last_compacted_seq: 0,
      last_included_seq: 0,
      metadata: %{}
    }

    assert {:ok, size} = SnapshotStore.persist(session_id, snapshot)
    assert size > 0

    assert {:ok, loaded} = SnapshotStore.load(session_id)
    assert loaded.strategy_id == "last_n"

    SnapshotStore.delete(session_id)
  end

  test "persist preserves queue metadata" do
    session_id = "snapshot-queue-test"
    queue = :queue.in(%{"seq" => 1, "content" => %{"text" => "hi"}}, :queue.new())

    snapshot = %Snapshot{
      strategy_id: "last_n",
      pending_messages: :queue.to_list(queue),
      summary_messages: [],
      token_count: 0,
      last_compacted_seq: 0,
      last_included_seq: 1,
      metadata: %{pending_queue: queue}
    }

    assert {:ok, _size} = SnapshotStore.persist(session_id, snapshot)
    assert {:ok, loaded} = SnapshotStore.load(session_id)
    assert :queue.is_queue(loaded.metadata[:pending_queue])

    SnapshotStore.delete(session_id)
  end
end
