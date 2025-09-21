defmodule Fleetlm.Chat.ThreadServerTest do
  use Fleetlm.DataCase, async: false

  alias Fleetlm.Chat
  alias Fleetlm.Chat.ThreadServer
  alias Fleetlm.Chat.Threads.Message

  setup do
    a_id = Ecto.UUID.generate()
    b_id = Ecto.UUID.generate()
    thread = Chat.ensure_dm!(a_id, b_id)

    {:ok, _pid} = ThreadServer.ensure(thread.id)

    Phoenix.PubSub.subscribe(Fleetlm.PubSub, "thread:#{thread.id}")
    Phoenix.PubSub.subscribe(Fleetlm.PubSub, "participant:#{a_id}")
    Phoenix.PubSub.subscribe(Fleetlm.PubSub, "participant:#{b_id}")

    {:ok, %{thread: thread, a_id: a_id, b_id: b_id}}
  end

  describe "ensure/1" do
    test "returns existing pid for already started server", %{thread: thread} do
      {:ok, pid1} = ThreadServer.ensure(thread.id)
      {:ok, pid2} = ThreadServer.ensure(thread.id)
      assert pid1 == pid2
    end
  end

  describe "send_message/3" do
    test "persists and broadcasts to thread and participants", %{thread: thread, a_id: a_id} do
      thread_id = thread.id

      {:ok, %Message{} = message} =
        ThreadServer.send_message(thread_id, %{thread_id: thread_id, sender_id: a_id, text: "hi"})

      assert_received {:thread_message, ^message}

      assert_receive {:thread_updated,
                      %{thread_id: ^thread_id, last_message_preview: "hi", sender_id: ^a_id}},
                     200

      assert_receive {:thread_updated,
                      %{thread_id: ^thread_id, last_message_preview: "hi", sender_id: ^a_id}},
                     200

      {:updated, payload} = ThreadServer.tick(thread_id, a_id, nil)
      assert payload.thread_id == thread_id
      assert payload.participant_id == a_id
      assert hd(payload.recent_messages).id == message.id
    end

    test "tick payload recent_messages capped at five", %{thread: thread, a_id: a_id, b_id: b_id} do
      thread_id = thread.id

      for idx <- 1..6 do
        sender = if rem(idx, 2) == 0, do: a_id, else: b_id

        {:ok, _msg} =
          ThreadServer.send_message(thread_id, %{
            thread_id: thread_id,
            sender_id: sender,
            text: "msg-#{idx}"
          })
      end

      {:updated, payload} = ThreadServer.tick(thread_id, a_id, nil)

      assert length(payload.recent_messages) == 5
      assert Enum.at(payload.recent_messages, 0).text == "msg-6"
      assert Enum.at(payload.recent_messages, 4).text == "msg-2"
    end
  end

  describe "tick/4" do
    test "returns idle when cursor is fresh", %{thread: thread, a_id: a_id, b_id: b_id} do
      {:ok, %Message{} = message} =
        ThreadServer.send_message(thread.id, %{
          thread_id: thread.id,
          sender_id: a_id,
          text: "ping"
        })

      {:updated, _} = ThreadServer.tick(thread.id, b_id, nil)
      assert :idle == ThreadServer.tick(thread.id, b_id, message.created_at)
    end

    test "returns error when participant not in thread", %{thread: thread} do
      assert {:error, :not_participant} = ThreadServer.tick(thread.id, Ecto.UUID.generate(), nil)
    end
  end
end
