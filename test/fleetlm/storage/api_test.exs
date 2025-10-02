defmodule FleetLM.Storage.APITest do
  use Fleetlm.TestCase

  test "get_messages returns entries from disk log before they are persisted" do
    session = create_test_session()
    session_id = session.id

    handler_id = attach_storage_read_handler()
    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok =
      API.append_message(
        session_id,
        1,
        "sender",
        "recipient",
        "text",
        %{"text" => "live"},
        %{}
      )

    {:ok, messages} = API.get_messages(session_id, 0, 1)

    assert [%Message{seq: 1, content: %{"text" => "live"}}] = messages
    assert Repo.aggregate(Message, :count, :id) == 0
    assert_receive {:storage_read_source, :disk_log}, 500
  end

  test "get_messages reads through to the database when disk log is empty" do
    session = create_test_session()
    session_id = session.id
    slot = :erlang.phash2(session_id, 64)

    handler_id = attach_storage_read_handler()
    on_exit(fn -> :telemetry.detach(handler_id) end)

    message = %Message{
      id: Ulid.generate(),
      session_id: session_id,
      sender_id: "sender",
      recipient_id: "recipient",
      seq: 1,
      kind: "text",
      content: %{"text" => "stored"},
      metadata: %{},
      shard_key: slot,
      inserted_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    }

    Repo.insert!(message)

    {:ok, messages} = API.get_messages(session_id, 0, 10)

    assert [%Message{id: id}] = messages
    assert id == message.id
    assert_receive {:storage_read_source, :database}, 500
  end

  test "get_messages merges persisted and live messages in sequence order" do
    session = create_test_session()
    session_id = session.id
    slot = :erlang.phash2(session_id, 64)

    persisted = %Message{
      id: Ulid.generate(),
      session_id: session_id,
      sender_id: "sender",
      recipient_id: "recipient",
      seq: 1,
      kind: "text",
      content: %{"text" => "persisted"},
      metadata: %{},
      shard_key: slot,
      inserted_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    }

    Repo.insert!(persisted)

    :ok =
      API.append_message(
        session_id,
        2,
        "sender",
        "recipient",
        "text",
        %{"text" => "live"},
        %{}
      )

    {:ok, messages} = API.get_messages(session_id, 0, 10)

    assert Enum.map(messages, & &1.seq) == [1, 2]
    assert Enum.map(messages, & &1.content["text"]) == ["persisted", "live"]
  end

  defp attach_storage_read_handler do
    handler_id = "storage_read_test_#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach(
      handler_id,
      [:fleetlm, :storage, :read],
      fn _event, _measurements, metadata, _ ->
        send(parent, {:storage_read_source, metadata.source})
      end,
      nil
    )

    handler_id
  end
end
