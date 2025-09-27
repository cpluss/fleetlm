defmodule Fleetlm.SessionBehaviourTest do
  use Fleetlm.DataCase, async: false

  alias Fleetlm.Conversation
  alias Fleetlm.Conversation.Participants
  alias Fleetlm.Agent
  alias Fleetlm.Runtime.{Cache, SessionServer, SessionSupervisor, InboxSupervisor, InboxServer}

  describe "session message delivery" do
    test "each message emits a single session event" do
      alice = unique_user("alice")
      bob = unique_user("bob")
      session = create_session(alice, bob)

      {:ok, pid} = SessionSupervisor.ensure_started(session.id)
      allow_db(pid)
      Phoenix.PubSub.subscribe(Fleetlm.PubSub, "session:" <> session.id)

      {:ok, message} =
        Conversation.append_message(session.id, %{
          sender_id: alice,
          kind: "text",
          content: %{text: "hello"}
        })

      assert_receive {:session_message, payload}, 500
      assert payload["id"] == message.id
      assert payload["content"]["text"] == "hello"

      refute_receive {:session_message, _}, 100
    end

    test "late join pulls backlog from session server" do
      alice = unique_user("alice")
      bob = unique_user("bob")
      session = create_session(alice, bob)

      {:ok, _} =
        Conversation.append_message(session.id, %{
          sender_id: alice,
          kind: "text",
          content: %{text: "queued"}
        })

      {:ok, pid} = SessionSupervisor.ensure_started(session.id)
      allow_db(pid)
      {:ok, tail} = SessionServer.load_tail(session.id)

      texts = Enum.map(tail, fn msg -> msg.content["text"] end)
      assert "queued" in texts
    end
  end

  describe "inbox aggregation" do
    test "inbox snapshot aggregates messages per session" do
      sender = unique_user("sender")
      recipient = unique_user("recipient")
      session = create_session(sender, recipient)

      {:ok, _} =
        Conversation.append_message(session.id, %{
          sender_id: sender,
          kind: "text",
          content: %{text: "Inbox once"}
        })

      {:ok, inbox_pid} = InboxSupervisor.ensure_started(recipient)
      allow_db(inbox_pid)

      {:ok, session_pid} = SessionSupervisor.ensure_started(session.id)
      allow_db(session_pid)
      Phoenix.PubSub.subscribe(Fleetlm.PubSub, "inbox:" <> recipient)

      :ok = InboxServer.flush(recipient)

      assert_receive {:inbox_snapshot, conversations}, 500
      entry = Enum.find(conversations, fn convo -> convo["session_id"] == session.id end)
      assert entry
      assert entry["last_message_id"]
    end

    test "hundreds of inbound sessions produce unique inbox entries" do
      recipient = unique_user("recipient")
      total = 50

      session_ids =
        Enum.map(1..total, fn idx ->
          sender_id = unique_user("sender#{idx}")
          session = create_session(sender_id, recipient)

          {:ok, _} =
            Conversation.append_message(session.id, %{
              sender_id: sender_id,
              kind: "text",
              content: %{text: "bulk #{idx}"}
            })

          session.id
        end)

      # Ensure all sessions are persisted before testing inbox aggregation
      Enum.each(session_ids, fn session_id ->
        assert %Conversation.ChatSession{} = Conversation.get_session!(session_id)
      end)

      {:ok, inbox_pid} = InboxSupervisor.ensure_started(recipient)
      allow_db(inbox_pid)

      Enum.each(session_ids, fn id ->
        {:ok, pid} = SessionSupervisor.ensure_started(id)
        allow_db(pid)
      end)

      Phoenix.PubSub.subscribe(Fleetlm.PubSub, "inbox:" <> recipient)

      :ok = InboxServer.flush(recipient)

      assert_receive {:inbox_snapshot, conversations}, 1000
      session_ids = MapSet.new(session_ids)

      Enum.each(conversations, fn convo ->
        assert MapSet.member?(session_ids, convo["session_id"])
      end)

      assert Enum.count(conversations) == MapSet.size(session_ids)
    end
  end

  describe "cache resilience" do
    test "history survives cache reset" do
      alice = unique_user("cache-alice")
      bob = unique_user("cache-bob")
      session = create_session(alice, bob)

      for n <- 1..10 do
        {:ok, _} =
          Conversation.append_message(session.id, %{
            sender_id: alice,
            kind: "text",
            content: %{text: "message #{n}"}
          })
      end

      :ok = Cache.reset()

      messages = Conversation.list_messages(session.id, limit: 20)
      texts = Enum.map(messages, fn msg -> msg.content["text"] end)
      assert Enum.count(texts) == 10
      assert "message 1" in texts
      assert "message 10" in texts
    end
  end

  describe "reconnect scenarios" do
    test "participant replays backlog after being offline" do
      alice = unique_user("alice")
      bob = unique_user("bob")
      session = create_session(alice, bob)

      {:ok, _} =
        Conversation.append_message(session.id, %{
          sender_id: alice,
          kind: "text",
          content: %{text: "initial"}
        })

      # Simulate clearing cache as if subscriber disconnected
      :ok = Cache.reset()

      {:ok, pid} = SessionSupervisor.ensure_started(session.id)
      allow_db(pid)
      {:ok, tail} = SessionServer.load_tail(session.id)
      texts = Enum.map(tail, fn msg -> msg.content["text"] end)
      assert "initial" in texts
    end

    test "offline participant receives backlog after connecting" do
      sender = unique_user("sender")
      offline = unique_user("offline")
      session = create_session(sender, offline)

      {:ok, _} =
        Conversation.append_message(session.id, %{
          sender_id: sender,
          kind: "text",
          content: %{text: "queued"}
        })

      assert [] == Registry.lookup(Fleetlm.Runtime.InboxRegistry, offline)

      {:ok, inbox_pid} = InboxSupervisor.ensure_started(offline)
      allow_db(inbox_pid)
      Phoenix.PubSub.subscribe(Fleetlm.PubSub, "inbox:" <> offline)

      :ok = InboxServer.flush(offline)

      assert_receive {:inbox_snapshot, conversations}, 500
      entry = Enum.find(conversations, fn convo -> convo["session_id"] == session.id end)
      assert entry
      assert entry["last_message_id"]
    end

    test "dispatcher only fires when agent endpoint enabled" do
      Participants.upsert_participant(%{id: "agent:bot", kind: "agent", display_name: "Bot"})

      Application.put_env(:fleetlm, :agent_dispatcher, %{mode: :test, pid: self()})

      Agent.upsert_endpoint!("agent:bot", %{
        origin_url: "https://example.com/webhook",
        status: "disabled"
      })

      client = unique_user("client")
      session = create_session(client, "agent:bot")

      {:ok, agent_inbox_pid} = InboxSupervisor.ensure_started("agent:bot")
      allow_db(agent_inbox_pid)

      {:ok, _} =
        Conversation.append_message(session.id, %{
          sender_id: client,
          kind: "text",
          content: %{text: "queued"}
        })

      refute_receive {:agent_dispatch, _}

      Agent.upsert_endpoint!("agent:bot", %{
        origin_url: "https://example.com/webhook",
        status: "enabled"
      })

      {:ok, _} =
        Conversation.append_message(session.id, %{
          sender_id: client,
          kind: "text",
          content: %{text: "live"}
        })

      assert_receive {:agent_dispatch, payload}, 500
      assert get_in(payload, ["message", "content", "text"]) == "live"
      refute_receive {:agent_dispatch, _}, 100
    after
      Application.delete_env(:fleetlm, :agent_dispatcher)
    end
  end

  defp create_session(a, b) do
    ensure_participant(a)
    ensure_participant(b)
    {:ok, session} = Conversation.start_session(%{initiator_id: a, peer_id: b})
    session
  end

  defp allow_db(pid), do: allow_sandbox_access(pid)

  defp unique_user(prefix) do
    "user:#{prefix}-#{System.unique_integer([:positive])}"
  end

  defp ensure_participant(id) do
    kind = if String.starts_with?(id, "agent:"), do: "agent", else: "user"

    Participants.upsert_participant(%{
      id: id,
      kind: kind,
      display_name: id
    })
  end
end
