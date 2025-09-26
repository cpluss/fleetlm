defmodule Fleetlm.SessionBehaviourTest do
  use Fleetlm.DataCase, async: false

  alias Fleetlm.{Participants, Sessions, Agents}
  alias Fleetlm.Sessions.{Cache, SessionServer, SessionSupervisor, InboxSupervisor}

  describe "session message delivery" do
    test "each message emits a single session event" do
      session = create_session("user:alice", "user:bob")

      {:ok, _} = SessionSupervisor.ensure_started(session.id)
      Phoenix.PubSub.subscribe(Fleetlm.PubSub, "session:" <> session.id)

      {:ok, message} =
        Sessions.append_message(session.id, %{
          sender_id: "user:alice",
          kind: "text",
          content: %{text: "hello"}
        })

      assert_receive {:session_message, payload}, 500
      assert payload["id"] == message.id
      assert payload["content"]["text"] == "hello"

      refute_receive {:session_message, _}, 100
    end

    test "late join pulls backlog from session server" do
      session = create_session("user:alice", "user:bob")

      {:ok, _} =
        Sessions.append_message(session.id, %{
          sender_id: "user:alice",
          kind: "text",
          content: %{text: "queued"}
        })

      {:ok, _} = SessionSupervisor.ensure_started(session.id)
      {:ok, tail} = SessionServer.load_tail(session.id)

      texts = Enum.map(tail, fn msg -> msg.content["text"] end)
      assert "queued" in texts
    end
  end

  describe "inbox aggregation" do
    test "inbox snapshot aggregates messages per session" do
      session = create_session("user:sender", "user:recipient")

      {:ok, _} =
        Sessions.append_message(session.id, %{
          sender_id: "user:sender",
          kind: "text",
          content: %{text: "Inbox once"}
        })

      {:ok, _} = InboxSupervisor.ensure_started("user:recipient")
      {:ok, _} = SessionSupervisor.ensure_started(session.id)
      Phoenix.PubSub.subscribe(Fleetlm.PubSub, "inbox:user:recipient")

      :ok = Fleetlm.Sessions.InboxServer.flush("user:recipient")

      assert_receive {:inbox_snapshot, conversations}, 500
      entry = Enum.find(conversations, fn convo -> convo["session_id"] == session.id end)
      assert entry
      assert entry["last_message_id"]

      refute_receive {:inbox_snapshot, _}, 100
    end

    test "hundreds of inbound sessions produce unique inbox entries" do
      recipient = "user:recipient"
      total = 50

      session_ids =
        Enum.map(1..total, fn idx ->
          sender_id = "user:sender#{idx}"
          session = create_session(sender_id, recipient)

          {:ok, _} =
            Sessions.append_message(session.id, %{
              sender_id: sender_id,
              kind: "text",
              content: %{text: "bulk #{idx}"}
            })

          session.id
        end)

      {:ok, _} = InboxSupervisor.ensure_started(recipient)
      Enum.each(session_ids, &SessionSupervisor.ensure_started/1)
      Phoenix.PubSub.subscribe(Fleetlm.PubSub, "inbox:" <> recipient)

      :ok = Fleetlm.Sessions.InboxServer.flush(recipient)

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
      session = create_session("user:cache-alice", "user:cache-bob")

      for n <- 1..10 do
        {:ok, _} =
          Sessions.append_message(session.id, %{
            sender_id: "user:cache-alice",
            kind: "text",
            content: %{text: "message #{n}"}
          })
      end

      :ok = Cache.reset()

      {:ok, _} = SessionSupervisor.ensure_started(session.id)
      {:ok, tail} = SessionServer.load_tail(session.id)

      texts = Enum.map(tail, fn msg -> msg.content["text"] end)
      assert Enum.count(texts) == 10
      assert "message 1" in texts
      assert "message 10" in texts
    end
  end

  describe "reconnect scenarios" do
    test "participant replays backlog after being offline" do
      session = create_session("user:alice", "user:bob")

      {:ok, _} =
        Sessions.append_message(session.id, %{
          sender_id: "user:alice",
          kind: "text",
          content: %{text: "initial"}
        })

      # Simulate clearing cache as if subscriber disconnected
      :ok = Cache.reset()

      {:ok, _} = SessionSupervisor.ensure_started(session.id)
      {:ok, tail} = SessionServer.load_tail(session.id)
      texts = Enum.map(tail, fn msg -> msg.content["text"] end)
      assert "initial" in texts
    end

    test "offline participant receives backlog after connecting" do
      session = create_session("user:sender", "user:offline")

      {:ok, _} =
        Sessions.append_message(session.id, %{
          sender_id: "user:sender",
          kind: "text",
          content: %{text: "queued"}
        })

      assert [] == Registry.lookup(Fleetlm.Sessions.InboxRegistry, "user:offline")

      {:ok, _} = InboxSupervisor.ensure_started("user:offline")
      Phoenix.PubSub.subscribe(Fleetlm.PubSub, "inbox:user:offline")

      :ok = Fleetlm.Sessions.InboxServer.flush("user:offline")

      assert_receive {:inbox_snapshot, conversations}, 500
      entry = Enum.find(conversations, fn convo -> convo["session_id"] == session.id end)
      assert entry
      assert entry["last_message_id"]
    end

    test "dispatcher only fires when agent endpoint enabled" do
      Participants.upsert_participant(%{id: "agent:bot", kind: "agent", display_name: "Bot"})

      Application.put_env(:fleetlm, :agent_dispatcher, %{mode: :test, pid: self()})

      Agents.upsert_endpoint!("agent:bot", %{
        origin_url: "https://example.com/webhook",
        status: "disabled"
      })

      session = create_session("user:client", "agent:bot")

      {:ok, _} =
        Sessions.append_message(session.id, %{
          sender_id: "user:client",
          kind: "text",
          content: %{text: "queued"}
        })

      refute_receive {:agent_dispatch, _}

      Agents.upsert_endpoint!("agent:bot", %{
        origin_url: "https://example.com/webhook",
        status: "enabled"
      })

      {:ok, _} =
        Sessions.append_message(session.id, %{
          sender_id: "user:client",
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
    {:ok, session} = Sessions.start_session(%{initiator_id: a, peer_id: b})
    session
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
