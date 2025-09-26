defmodule Fleetlm.Sessions.InboxServerTest do
  use Fleetlm.DataCase, async: false

  alias Fleetlm.Participants
  alias Fleetlm.Sessions
  alias Fleetlm.Sessions.{Cache, InboxServer, InboxSupervisor, SessionSupervisor}

  setup do
    :ok = Cache.reset()
    on_exit(fn -> Cache.reset() end)
    :ok
  end

  describe "InboxServer state hydration" do
    test "loads cached snapshot on init" do
      participant = "user:cached"
      snapshot = [%{"session_id" => "existing"}]

      :ok = Cache.put_inbox_snapshot(participant, snapshot)

      {:ok, pid} = InboxSupervisor.ensure_started(participant)
      allow_sandbox_access(pid)
      state = :sys.get_state(pid)

      assert state.snapshot == snapshot
    end
  end

  describe "inbox broadcasts" do
    setup do
      {:ok, sender} = ensure_participant("user:sender")
      {:ok, recipient} = ensure_participant("user:recipient")

      {:ok, session} =
        Sessions.start_session(%{
          initiator_id: sender.id,
          peer_id: recipient.id
        })

      Phoenix.PubSub.subscribe(Fleetlm.PubSub, "inbox:" <> recipient.id)
      {:ok, inbox_pid} = InboxSupervisor.ensure_started(recipient.id)
      allow_sandbox_access(inbox_pid)

      {:ok, session_pid} = SessionSupervisor.ensure_started(session.id)
      allow_sandbox_access(session_pid)

      %{session: session, sender: sender, recipient: recipient}
    end

    test "enqueue_update via append caches snapshot", %{
      session: session,
      sender: sender,
      recipient: recipient
    } do
      {:ok, _message} =
        Sessions.append_message(session.id, %{
          sender_id: sender.id,
          kind: "text",
          content: %{text: "hello"}
        })

      assert Sessions.unread_count(Sessions.get_session!(session.id), recipient.id) == 1
      sessions = Sessions.list_sessions_for_participant(recipient.id)
      assert Enum.any?(sessions, fn s -> Sessions.unread_count(s, recipient.id) == 1 end)

      assert_receive {:inbox_snapshot, snapshot}, 500

      entry = Enum.find(snapshot, &(&1["session_id"] == session.id))
      refute is_nil(entry)
      assert entry["session_id"] == session.id
      assert Enum.any?(snapshot, &(&1["unread_count"] == 1))

      assert {:ok, cached} = Cache.fetch_inbox_snapshot(recipient.id)
      assert cached == snapshot
    end

    test "flush triggers a fresh broadcast", %{
      session: session,
      sender: sender,
      recipient: recipient
    } do
      {:ok, _message} =
        Sessions.append_message(session.id, %{
          sender_id: sender.id,
          kind: "text",
          content: %{text: "hello"}
        })

      assert_receive {:inbox_snapshot, _snapshot}, 500

      :ok = InboxServer.flush(recipient.id)

      assert_receive {:inbox_snapshot, snapshot}, 500
      assert Enum.any?(snapshot, &(&1["session_id"] == session.id))
    end

    test "mark_read flush updates unread counts", %{
      session: session,
      sender: sender,
      recipient: recipient
    } do
      {:ok, message} =
        Sessions.append_message(session.id, %{
          sender_id: sender.id,
          kind: "text",
          content: %{text: "hello"}
        })

      assert_receive {:inbox_snapshot, snapshot}, 500
      entry = Enum.find(snapshot, &(&1["session_id"] == session.id))
      assert entry
      assert Enum.any?(snapshot, &(&1["unread_count"] == 1))

      {:ok, _} = Sessions.mark_read(session.id, recipient.id, message_id: message.id)

      assert_receive {:inbox_snapshot, snapshot2}, 500
      entry2 = Enum.find(snapshot2, &(&1["session_id"] == session.id))
      assert entry2["unread_count"] == 0
    end
  end

  defp ensure_participant(id, kind \\ "user") do
    Participants.upsert_participant(%{
      id: id,
      kind: kind,
      display_name: id
    })
  end
end
