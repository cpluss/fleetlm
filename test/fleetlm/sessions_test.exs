defmodule Fleetlm.SessionsTest do
  use Fleetlm.DataCase, async: true

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
  end
end
