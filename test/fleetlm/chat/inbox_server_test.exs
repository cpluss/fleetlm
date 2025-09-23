defmodule Fleetlm.Chat.InboxServerTest do
  use Fleetlm.DataCase

  alias Fleetlm.Chat.{Cache, Events, InboxServer, InboxSupervisor}

  setup do
    Cache.reset()
    :ok
  end

  defp start_server(participant) do
    {:ok, pid} = InboxSupervisor.ensure_started(participant)
    on_exit(fn -> Process.exit(pid, :normal) end)
    pid
  end

  defp subscribe(participant) do
    Phoenix.PubSub.subscribe(Fleetlm.PubSub, "inbox:" <> participant)
  end

  test "snapshot hydrates from cache when available" do
    participant = "user:snapshot"

    entry = %Events.DmActivity{
      participant_id: participant,
      dm_key: "dm:one",
      other_participant_id: "user:other",
      last_sender_id: "user:other",
      last_message_text: "cached",
      last_message_at: DateTime.utc_now(),
      unread_count: 3
    }

    Cache.put_inbox_snapshot(participant, [entry])
    start_server(participant)

    assert {:ok, snapshot} = InboxServer.snapshot(participant)
    assert [%{"dm_key" => "dm:one", "unread_count" => 3}] = snapshot
  end

  test "flush aggregates updates per conversation" do
    participant = "user:aggregate"
    pid = start_server(participant)
    subscribe(participant)

    activity = %Events.DmActivity{
      participant_id: participant,
      dm_key: "dm:agg",
      other_participant_id: "user:bob",
      last_sender_id: "user:bob",
      last_message_text: "first",
      last_message_at: DateTime.utc_now(),
      unread_count: 0
    }

    InboxServer.enqueue_activity(participant, activity)
    InboxServer.enqueue_activity(participant, %{activity | last_message_text: "second"})
    :ok = InboxServer.flush(participant)

    assert_receive {:inbox_delta,
                    %{updates: [%{"last_message_text" => "second", "unread_count" => 2}]}}

    state = :sys.get_state(pid)
    entry = Map.fetch!(state.entries, "dm:agg")
    assert entry.unread_count == 2
    assert entry.last_message_text == "second"
    assert state.pending == %{}
  end

  test "flush emits aggregated updates for multiple conversations without payload bodies" do
    participant = "user:multi"
    start_server(participant)
    subscribe(participant)

    now = DateTime.utc_now()

    Enum.each(["dm:a", "dm:b"], fn dm ->
      activity = %Events.DmActivity{
        participant_id: participant,
        dm_key: dm,
        other_participant_id: "user:" <> dm,
        last_sender_id: "user:" <> dm,
        last_message_text: dm,
        last_message_at: now,
        unread_count: 0
      }

      InboxServer.enqueue_activity(participant, activity)
    end)

    :ok = InboxServer.flush(participant)

    assert_receive {:inbox_delta, %{updates: updates}}
    assert length(updates) == 2

    Enum.each(updates, fn update ->
      refute Map.has_key?(update, "text")
      refute Map.has_key?(update, "metadata")
    end)

    refute_receive {:inbox_delta, _}, 50
  end

  test "mark_read resets unread count" do
    participant = "user:mark"
    start_server(participant)

    activity = %Events.DmActivity{
      participant_id: participant,
      dm_key: "dm:read",
      other_participant_id: "user:bob",
      last_sender_id: "user:bob",
      last_message_text: "ping",
      last_message_at: DateTime.utc_now(),
      unread_count: 0
    }

    InboxServer.enqueue_activity(participant, activity)
    InboxServer.enqueue_activity(participant, %{activity | last_message_text: "pong"})
    :ok = InboxServer.flush(participant)

    :ok = InboxServer.mark_read(participant, "dm:read")
    :ok = InboxServer.flush(participant)

    {:ok, snapshot} = InboxServer.snapshot(participant)
    assert [%{"unread_count" => 0}] = Enum.filter(snapshot, &(&1["dm_key"] == "dm:read"))
  end
end
