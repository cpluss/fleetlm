defmodule Fleetlm.Runtime.EventsTest do
  use Fleetlm.DataCase, async: false

  alias Fleetlm.Conversation.Participants
  alias Fleetlm.Conversation
  alias Fleetlm.Runtime.{Cache, InboxSupervisor, SessionSupervisor}

  setup do
    :ok = Cache.reset()
    on_exit(fn -> Cache.reset() end)

    {:ok, alice} = ensure_participant("user:alice")
    {:ok, bob} = ensure_participant("user:bob")

    {:ok, session} =
      Conversation.start_session(%{
        initiator_id: alice.id,
        peer_id: bob.id
      })

    Phoenix.PubSub.subscribe(Fleetlm.PubSub, "session:" <> session.id)
    Phoenix.PubSub.subscribe(Fleetlm.PubSub, "inbox:" <> alice.id)
    Phoenix.PubSub.subscribe(Fleetlm.PubSub, "inbox:" <> bob.id)

    {:ok, pid} = SessionSupervisor.ensure_started(session.id)
    allow_sandbox_access(pid)

    {:ok, alice_inbox} = InboxSupervisor.ensure_started(alice.id)
    allow_sandbox_access(alice_inbox)

    {:ok, bob_inbox} = InboxSupervisor.ensure_started(bob.id)
    allow_sandbox_access(bob_inbox)

    %{session: session, alice: alice, bob: bob}
  end

  test "appending messages emits session and inbox broadcasts", %{session: session, alice: alice} do
    {:ok, message} =
      Conversation.append_message(session.id, %{
        sender_id: alice.id,
        kind: "text",
        content: %{text: "Hi Bob"}
      })

    assert_receive {:session_message, payload}, 1000
    assert payload["id"] == message.id
    assert payload["session_id"] == session.id
    assert payload["content"]["text"] == "Hi Bob"

    Process.sleep(100)

    # Flush inbox servers to ensure fresh snapshots with updated unread counts
    Fleetlm.Runtime.InboxServer.flush(alice.id)
    Fleetlm.Runtime.InboxServer.flush(session.peer_id)

    Enum.each([alice.id, session.peer_id], fn participant_id ->
      assert_receive {:inbox_snapshot, snapshot}, 1000
      assert Enum.any?(snapshot, &(&1["session_id"] == session.id))
      entry = Enum.find(snapshot, &(&1["session_id"] == session.id))

      # Verify the unread count is correct based on who sent the message
      if participant_id == alice.id do
        # Alice sent the message, so her unread count should be 0
        assert entry["unread_count"] == 0
      else
        # Bob received the message, so his unread count should be 1
        assert entry["unread_count"] == 1
      end
    end)
  end

  defp ensure_participant(id, kind \\ "user") do
    Participants.upsert_participant(%{
      id: id,
      kind: kind,
      display_name: id
    })
  end
end
