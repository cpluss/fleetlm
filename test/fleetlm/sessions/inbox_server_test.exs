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
      {:ok, _} = InboxSupervisor.ensure_started(recipient.id)
      {:ok, _} = SessionSupervisor.ensure_started(session.id)

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

      assert_receive {:inbox_snapshot, snapshot}, 500

      entry = Enum.find(snapshot, &(&1["session_id"] == session.id))
      refute is_nil(entry)
      assert entry["session_id"] == session.id

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
  end

  defp ensure_participant(id, kind \\ "user") do
    Participants.upsert_participant(%{
      id: id,
      kind: kind,
      display_name: id
    })
  end
end
