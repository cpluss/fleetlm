defmodule Fleetlm.Sessions.MarkReadFallbackTest do
  use Fleetlm.DataCase, async: false

  alias Fleetlm.Participants
  alias Fleetlm.Sessions
  alias Fleetlm.Sessions.{InboxSupervisor, SessionSupervisor}

  setup do
    {:ok, alice} =
      Participants.upsert_participant(%{
        id: "user:alice",
        kind: "user",
        display_name: "Alice"
      })

    {:ok, bob} =
      Participants.upsert_participant(%{
        id: "user:bob",
        kind: "user",
        display_name: "Bob"
      })

    {:ok, session} =
      Sessions.start_session(%{
        initiator_id: alice.id,
        peer_id: bob.id
      })

    {:ok, session_pid} = SessionSupervisor.ensure_started(session.id)
    Fleetlm.DataCase.allow_sandbox_access(session_pid)

    {:ok, inbox_pid} = InboxSupervisor.ensure_started(bob.id)
    Fleetlm.DataCase.allow_sandbox_access(inbox_pid)

    {:ok, %{session: session, alice: alice, bob: bob}}
  end

  test "mark_read without explicit message id uses last message", %{
    session: session,
    bob: bob,
    alice: alice
  } do
    {:ok, message} =
      Sessions.append_message(session.id, %{
        sender_id: alice.id,
        kind: "text",
        content: %{text: "hey"}
      })

    {:ok, updated} = Sessions.mark_read(session.id, bob.id)

    assert updated.peer_last_read_id == message.id
    assert Sessions.unread_count(updated, bob.id) == 0
  end

  test "mark_read returns :message_not_found when id outside session", %{
    session: session,
    bob: bob
  } do
    assert {:error, :message_not_found} =
             Sessions.mark_read(session.id, bob.id, message_id: "01FINVALID")
  end
end
