defmodule Fleetlm.Runtime.InboxServerTest do
  use Fleetlm.StorageCase, async: false

  alias Fleetlm.Runtime.{InboxServer, Router}

  setup do
    # Create two sessions for alice with different participants
    session1 = create_test_session("alice", "bob")
    session2 = create_test_session("alice", "charlie")

    {:ok, session1: session1, session2: session2}
  end

  describe "start_link/1" do
    test "starts inbox server and loads sessions", %{session1: session1, session2: session2} do
      {:ok, pid} = InboxServer.start_link("alice")

      on_exit(fn ->
        if Process.alive?(pid) do
          catch_exit(GenServer.stop(pid, :normal))
        end
      end)

      assert Process.alive?(pid)

      # Get snapshot
      {:ok, snapshot} = InboxServer.get_snapshot("alice")

      # Should have 2 sessions
      assert length(snapshot) == 2
      session_ids = Enum.map(snapshot, & &1["session_id"]) |> MapSet.new()
      assert MapSet.member?(session_ids, session1.id)
      assert MapSet.member?(session_ids, session2.id)
    end

    test "initializes with no messages", %{session1: _session1} do
      {:ok, pid} = InboxServer.start_link("alice")

      on_exit(fn ->
        if Process.alive?(pid) do
          catch_exit(GenServer.stop(pid, :normal))
        end
      end)

      {:ok, snapshot} = InboxServer.get_snapshot("alice")

      # Find alice's session
      alice_session = Enum.find(snapshot, &(&1["session_id"] != nil))

      # Should have no last message
      assert alice_session["last_message"] == nil
    end
  end

  describe "event-driven updates" do
    setup %{session1: session1, session2: session2} do
      {:ok, inbox_pid} = InboxServer.start_link("alice")

      on_exit(fn ->
        if Process.alive?(inbox_pid) do
          catch_exit(GenServer.stop(inbox_pid, :normal))
        end
      end)

      %{inbox_pid: inbox_pid, session: session1, session2: session2}
    end

    test "updates inbox when message arrives via PubSub", %{session: session} do
      # Subscribe to inbox updates
      Phoenix.PubSub.subscribe(Fleetlm.PubSub, "inbox:alice")

      # Send a message via Router (which broadcasts to session PubSub)
      {:ok, message} =
        Router.append_message(
          session.id,
          "bob",
          "text",
          %{"text" => "hello alice"},
          %{}
        )

      # Should receive inbox snapshot update
      assert_receive {:inbox_snapshot, snapshot}, 1000

      # Find the session in snapshot
      updated_session = Enum.find(snapshot, &(&1["session_id"] == session.id))

      # Should have updated last message
      assert updated_session["last_message"]["seq"] == message.seq
      assert updated_session["last_message"]["sender_id"] == "bob"
    end

    test "updates for messages from self too", %{session: session} do
      Phoenix.PubSub.subscribe(Fleetlm.PubSub, "inbox:alice")

      # Alice sends a message
      {:ok, message} =
        Router.append_message(
          session.id,
          "alice",
          "text",
          %{"text" => "hello bob"},
          %{}
        )

      # Should receive inbox snapshot update
      assert_receive {:inbox_snapshot, snapshot}, 1000

      updated_session = Enum.find(snapshot, &(&1["session_id"] == session.id))

      # Should update last message regardless of sender
      assert updated_session["last_message"]["seq"] == message.seq
      assert updated_session["last_message"]["sender_id"] == "alice"
    end

    test "sorts sessions by last message time", %{session1: session1, session2: session2, inbox_pid: _inbox_pid} do
      # Inbox already started by setup
      Phoenix.PubSub.subscribe(Fleetlm.PubSub, "inbox:alice")

      # Send message to session2 first
      {:ok, _} = Router.append_message(session2.id, "charlie", "text", %{"text" => "1"}, %{})
      assert_receive {:inbox_snapshot, _}, 1000

      # Then send message to session1
      {:ok, _} = Router.append_message(session1.id, "bob", "text", %{"text" => "2"}, %{})
      assert_receive {:inbox_snapshot, snapshot}, 1000

      # session1 should be first (most recent)
      assert hd(snapshot)["session_id"] == session1.id
    end
  end
end