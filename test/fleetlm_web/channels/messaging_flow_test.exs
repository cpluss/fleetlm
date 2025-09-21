defmodule FleetlmWeb.MessagingFlowTest do
  use FleetlmWeb.ChannelCase, async: false

  alias Fleetlm.Chat

  @tick_timeout 300

  setup do
    a = Ecto.UUID.generate()
    b = Ecto.UUID.generate()
    thread = Chat.ensure_dm!(a, b)
    {:ok, thread_server} = Chat.ensure_thread_runtime(thread.id)
    Ecto.Adapters.SQL.Sandbox.allow(Fleetlm.Repo, self(), thread_server)

    {:ok, thread: thread, a: a, b: b, thread_id: thread.id}
  end

  test "late joiner receives backlog and live updates", %{thread_id: thread_id, a: a, b: b} do
    {_, _a_part} = join_participant(a)
    {a_thread_reply, a_thread_socket} = join_thread(a, thread_id)
    assert a_thread_reply == %{"messages" => []}

    ref = push(a_thread_socket, "message:new", %{"text" => "foo"})
    assert_reply ref, :ok, %{"text" => "foo", "sender_id" => ^a}
    assert_push "message", %{"thread_id" => ^thread_id, "text" => "foo", "sender_id" => ^a}

    {b_part_reply, _b_part} = join_participant(b)
    assert_thread_metadata(b_part_reply, thread_id, "foo")

    {b_thread_reply, b_thread_socket} = join_thread(b, thread_id)
    assert [%{"text" => "foo", "sender_id" => ^a}] = b_thread_reply["messages"]
    assert_push "message", %{"thread_id" => ^thread_id, "text" => "foo", "sender_id" => ^a}

    ref = push(b_thread_socket, "message:new", %{"text" => "bar"})
    assert_reply ref, :ok, %{"text" => "bar", "sender_id" => ^b}
    assert_push "message", %{"thread_id" => ^thread_id, "text" => "bar", "sender_id" => ^b}
    assert_push "message", %{"thread_id" => ^thread_id, "text" => "bar", "sender_id" => ^b}

    updates = collect_tick_updates(2)

    Enum.each(updates, fn update ->
      assert update["thread_id"] == thread_id
      assert update["last_message_preview"] == "bar"
      assert update["sender_id"] == b
    end)

    assert Enum.sort(Enum.map(updates, & &1["participant_id"])) == Enum.sort([a, b])
  end

  defp join_participant(participant_id) do
    socket = socket(FleetlmWeb.UserSocket, nil, %{participant_id: participant_id})
    {:ok, reply, socket} = subscribe_and_join(socket, FleetlmWeb.ParticipantChannel, "participant:#{participant_id}")
    {reply, socket}
  end

  defp join_thread(participant_id, thread_id) do
    socket = socket(FleetlmWeb.UserSocket, nil, %{participant_id: participant_id})
    {:ok, reply, socket} = subscribe_and_join(socket, FleetlmWeb.ThreadChannel, "thread:#{thread_id}")
    {reply, socket}
  end

  defp assert_thread_metadata(%{"threads" => threads}, thread_id, preview) do
    meta = Enum.find(threads, &(&1["thread_id"] == thread_id))
    assert meta
    assert meta["last_message_preview"] == preview
  end

  defp collect_tick_updates(count), do: collect_tick_updates(count, [])

  defp collect_tick_updates(0, acc), do: acc

  defp collect_tick_updates(count, acc) do
    assert_push "tick", %{"updates" => updates}, @tick_timeout
    collect_tick_updates(count - 1, acc ++ updates)
  end
end
