defmodule Fleetlm.ChatTest do
  use Fleetlm.DataCase, async: true

  alias Fleetlm.Chat
  alias Fleetlm.Chat.Threads.{Message, Participant, Thread}
  alias Fleetlm.Repo

  describe "dm_key/2" do
    test "returns a stable ordering" do
      assert Chat.dm_key("b", "a") == "a:b"
      assert Chat.dm_key("a", "a") == "a:a"
    end
  end

  describe "ensure_dm!/2" do
    test "is idempotent and ensures participants" do
      a_id = Ecto.UUID.generate()
      b_id = Ecto.UUID.generate()

      thread = Chat.ensure_dm!(a_id, b_id)
      assert %Thread{kind: "dm"} = thread

      thread = Repo.preload(thread, :participants)
      assert Enum.sort(by_participant_id(thread.participants)) == Enum.sort([a_id, b_id])

      same_thread = Chat.ensure_dm!(a_id, b_id)
      assert same_thread.id == thread.id

      participants =
        Participant
        |> where(thread_id: ^thread.id)
        |> Repo.all()

      assert length(participants) == 2
      assert Enum.all?(participants, &(&1.role == "user"))
    end
  end

  describe "send_message/2" do
    test "persists message and updates participant metadata" do
      a_id = Ecto.UUID.generate()
      b_id = Ecto.UUID.generate()
      thread = Chat.ensure_dm!(a_id, b_id)

      {:ok, message} = Chat.send_message(%{thread_id: thread.id, sender_id: a_id, text: "hello"})

      persisted = Repo.get!(Message, message.id)
      assert persisted.text == "hello"
      assert persisted.role == "user"
      assert is_integer(persisted.shard_key)

      sender = participant(thread.id, a_id)
      recipient = participant(thread.id, b_id)

      assert sender.last_message_preview == "hello"
      assert sender.read_cursor_at == message.created_at
      assert sender.last_message_at == message.created_at

      assert recipient.last_message_preview == "hello"
      assert recipient.last_message_at == message.created_at
      assert is_nil(recipient.read_cursor_at)
    end

    test "returns error when thread is missing" do
      {:error, :thread, :not_found} =
        Chat.send_message(%{thread_id: Ecto.UUID.generate(), sender_id: Ecto.UUID.generate()})
    end
  end

  describe "list_thread_messages/2" do
    test "orders newest first and supports before cursor" do
      a_id = Ecto.UUID.generate()
      b_id = Ecto.UUID.generate()
      thread = Chat.ensure_dm!(a_id, b_id)

      {:ok, first} = Chat.send_message(%{thread_id: thread.id, sender_id: a_id, text: "first"})
      Process.sleep(5)
      {:ok, second} = Chat.send_message(%{thread_id: thread.id, sender_id: b_id, text: "second"})

      messages = Chat.list_thread_messages(thread.id)
      assert Enum.map(messages, & &1.id) == [second.id, first.id]

      older =
        Chat.list_thread_messages(thread.id,
          before: %{created_at: second.created_at, id: second.id}
        )

      assert Enum.map(older, & &1.id) == [first.id]
    end
  end

  describe "list_threads_for_participant/2" do
    test "sorts descending by last message timestamp" do
      a_id = Ecto.UUID.generate()
      b_id = Ecto.UUID.generate()
      c_id = Ecto.UUID.generate()

      first_thread = Chat.ensure_dm!(a_id, b_id)
      second_thread = Chat.ensure_dm!(a_id, c_id)

      {:ok, _} = Chat.send_message(%{thread_id: first_thread.id, sender_id: b_id, text: "ping"})
      Process.sleep(5)
      {:ok, _} = Chat.send_message(%{thread_id: second_thread.id, sender_id: a_id, text: "pong"})

      threads = Chat.list_threads_for_participant(a_id)
      assert Enum.map(threads, & &1.thread.id) == [second_thread.id, first_thread.id]
    end
  end

  describe "ack_read/3" do
    test "updates read cursor monotonically" do
      a_id = Ecto.UUID.generate()
      b_id = Ecto.UUID.generate()
      thread = Chat.ensure_dm!(a_id, b_id)

      {:ok, message} = Chat.send_message(%{thread_id: thread.id, sender_id: a_id, text: "hello"})

      {:ok, updated} = Chat.ack_read(thread.id, b_id, message.created_at)
      assert updated.read_cursor_at == message.created_at

      earlier = DateTime.add(message.created_at, -60, :second)
      {:ok, same} = Chat.ack_read(thread.id, b_id, earlier)
      assert same.read_cursor_at == message.created_at
    end

    test "returns error if participant missing" do
      assert {:error, :not_found} =
               Chat.ack_read(Ecto.UUID.generate(), Ecto.UUID.generate(), DateTime.utc_now())
    end
  end

  defp participant(thread_id, participant_id) do
    Participant
    |> Repo.get_by!(thread_id: thread_id, participant_id: participant_id)
  end

  defp by_participant_id(participants) do
    Enum.map(participants, & &1.participant_id)
  end
end
