defmodule Fleetlm.SessionsTest do
  use Fleetlm.DataCase, async: false

  alias Fleetlm.Participants
  alias Fleetlm.Sessions
  alias Fleetlm.Sessions.ChatSession
  alias Fleetlm.Sessions.ChatMessage

  setup do
    {:ok, user_a} =
      Participants.upsert_participant(%{
        id: "user:alice",
        kind: "user",
        display_name: "Alice"
      })

    {:ok, user_b} =
      Participants.upsert_participant(%{
        id: "agent:bot",
        kind: "agent",
        display_name: "Bot"
      })

    %{user: user_a, agent: user_b}
  end

  describe "start_session/1" do
    test "creates agent session when one participant is agent", %{user: user, agent: agent} do
      assert {:ok, %ChatSession{} = session} =
               Sessions.start_session(%{
                 initiator_id: user.id,
                 peer_id: agent.id
               })

      assert session.kind == "agent_dm"
      assert session.agent_id == agent.id
    end

    test "rejects sessions where both participants are the same", %{user: user} do
      assert {:error, %Ecto.Changeset{} = changeset} =
               Sessions.start_session(%{
                 initiator_id: user.id,
                 peer_id: user.id
               })

      assert {"must be different from initiator", _} =
               Keyword.fetch!(changeset.errors, :peer_id)
    end
  end

  describe "append_message/2" do
    setup %{user: user, agent: agent} do
      {:ok, session} =
        Sessions.start_session(%{
          initiator_id: user.id,
          peer_id: agent.id
        })

      %{session: session}
    end

    test "persists message and updates session", %{session: session, user: user} do
      assert {:ok, %ChatMessage{} = message} =
               Sessions.append_message(session.id, %{
                 sender_id: user.id,
                 kind: "text",
                 content: %{text: "hi"}
               })

      updated_session = Sessions.get_session!(session.id)
      assert updated_session.last_message_id == message.id
      naive_dt = DateTime.from_naive!(message.inserted_at, "Etc/UTC")
      assert DateTime.compare(updated_session.last_message_at, naive_dt) == :eq
    end

    test "list_messages returns ULID ordered messages", %{
      session: session,
      user: user,
      agent: agent
    } do
      {:ok, first} =
        Sessions.append_message(session.id, %{
          sender_id: user.id,
          kind: "text",
          content: %{text: "hello"}
        })

      Process.sleep(5)

      {:ok, second} =
        Sessions.append_message(session.id, %{
          sender_id: agent.id,
          kind: "system",
          content: %{text: "reply"}
        })

      messages = Sessions.list_messages(session.id)
      assert Enum.map(messages, & &1.id) == [first.id, second.id]

      tail = Sessions.list_messages(session.id, after_id: first.id)
      assert Enum.map(tail, & &1.id) == [second.id]
    end

    test "list_messages isolates session history", %{session: session, user: user} do
      {:ok, other_user} =
        Participants.upsert_participant(%{
          id: "user:charlie",
          kind: "user",
          display_name: "Charlie"
        })

      {:ok, other_session} =
        Sessions.start_session(%{
          initiator_id: user.id,
          peer_id: other_user.id
        })

      {:ok, _} =
        Sessions.append_message(session.id, %{
          sender_id: user.id,
          kind: "text",
          content: %{text: "primary"}
        })

      {:ok, _} =
        Sessions.append_message(other_session.id, %{
          sender_id: user.id,
          kind: "text",
          content: %{text: "secondary"}
        })

      messages = Sessions.list_messages(session.id)
      assert Enum.count(messages) == 1
      assert Enum.at(messages, 0).session_id == session.id
    end
  end

  describe "mark_read/3" do
    setup %{user: user, agent: agent} do
      {:ok, session} =
        Sessions.start_session(%{
          initiator_id: user.id,
          peer_id: agent.id
        })

      {:ok, message} =
        Sessions.append_message(session.id, %{
          sender_id: user.id,
          kind: "text",
          content: %{text: "hey"}
        })

      %{session: session, message: message}
    end

    test "updates peer read markers and clears unread count", %{
      session: session,
      message: message,
      agent: agent
    } do
      {:ok, updated} =
        Sessions.mark_read(session.id, agent.id, message_id: message.id)

      assert updated.peer_last_read_id == message.id
      assert match?(%DateTime{}, updated.peer_last_read_at)
      assert Sessions.unread_count(updated, agent.id) == 0
    end

    test "rejects unknown participant", %{session: session, message: message} do
      assert {:error, :invalid_participant} =
               Sessions.mark_read(session.id, "user:ghost", message_id: message.id)
    end
  end

  describe "list_sessions_for_participant/2" do
    test "returns all sessions for a participant", %{user: user, agent: agent} do
      {:ok, other_user} =
        Participants.upsert_participant(%{
          id: "user:bob",
          kind: "user",
          display_name: "Bob"
        })

      {:ok, agent_session} =
        Sessions.start_session(%{
          initiator_id: user.id,
          peer_id: agent.id
        })

      {:ok, human_session} =
        Sessions.start_session(%{
          initiator_id: user.id,
          peer_id: other_user.id
        })

      sessions = Sessions.list_sessions_for_participant(user.id, limit: 10)
      ids = MapSet.new(Enum.map(sessions, & &1.id))

      assert MapSet.member?(ids, agent_session.id)
      assert MapSet.member?(ids, human_session.id)
      assert Enum.count(sessions) == 2
    end
  end
end
