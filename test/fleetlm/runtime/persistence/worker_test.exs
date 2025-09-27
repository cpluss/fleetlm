defmodule Fleetlm.Runtime.Persistence.WorkerTest do
  use Fleetlm.DataCase

  alias Fleetlm.Runtime.Persistence.Worker
  alias Fleetlm.Runtime.Storage.Entry
  alias Fleetlm.Conversation.{ChatMessage, Participants}
  alias Fleetlm.Conversation
  alias Ulid

  setup do
    Application.put_env(:fleetlm, :persistence_worker_mode, :noop)

    on_exit(fn -> Application.put_env(:fleetlm, :persistence_worker_mode, :noop) end)

    :ok
  end

  describe "noop mode" do
    test "enqueue/2 immediately satisfies await/3" do
      {:ok, pid} = Worker.start_link(slot: 21)
      allow_sandbox_access(pid)

      entry = build_entry("session-id", 1)

      Worker.enqueue(pid, entry)

      assert :ok = Worker.await(pid, entry.message_id, 200)
      assert :ok = Worker.await(pid, entry.message_id, 200)
    end
  end

  describe "live mode" do
    setup do
      Application.put_env(:fleetlm, :persistence_worker_mode, :live)

      {:ok, _initiator} =
        Participants.upsert_participant(%{
          id: "user:initiator",
          kind: "user",
          display_name: "Init"
        })

      {:ok, _peer} =
        Participants.upsert_participant(%{
          id: "user:peer",
          kind: "user",
          display_name: "Peer"
        })

      {:ok, session} =
        Conversation.start_session(%{
          initiator_id: "user:initiator",
          peer_id: "user:peer"
        })

      on_exit(fn -> Application.put_env(:fleetlm, :persistence_worker_mode, :noop) end)

      {:ok, session: session}
    end

    test "persists entries and notifies waiters", %{session: session} do
      {:ok, pid} = Worker.start_link(slot: 7)
      allow_sandbox_access(pid)

      entry =
        build_entry(session.id, 1, session.initiator_id, %{
          id: session.id,
          agent_id: session.agent_id,
          initiator_id: session.initiator_id,
          peer_id: session.peer_id,
          kind: session.kind,
          last_message_id: session.last_message_id,
          last_message_at: session.last_message_at
        })

      Worker.enqueue(pid, entry)

      assert :ok = Worker.await(pid, entry.message_id, 1_000)

      persisted = Conversation.list_messages(session.id, limit: 5)

      assert Enum.any?(persisted, fn message ->
               message.sender_id == session.initiator_id and message.content["text"] == "hello"
             end)
    end
  end

  defp build_entry(session_id, seq, sender_id \\ "sender", session_snapshot \\ nil) do
    inserted_at = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    message_id = Ulid.generate()

    message =
      struct(ChatMessage, %{
        id: message_id,
        session_id: session_id,
        sender_id: sender_id,
        kind: "text",
        content: %{text: "hello"},
        metadata: %{},
        shard_key: :erlang.phash2(session_id, 1024),
        inserted_at: inserted_at,
        session: session_snapshot
      })

    Entry.from_message(21, seq, "idem-#{seq}", message)
  end
end
