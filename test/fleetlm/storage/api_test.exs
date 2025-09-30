defmodule FleetLM.Storage.APITest do
  use Fleetlm.StorageCase, async: false

  test "get_messages returns entries from disk log before they are persisted" do
    session = create_test_session()
    session_id = session.id

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

    {:ok, messages} = API.get_messages(session_id, 0, 10)

    assert [%Message{seq: 1, content: %{"text" => "live"}}] = messages
    assert Repo.aggregate(Message, :count, :id) == 0
  end

  test "get_messages reads through to the database when disk log is empty" do
    session = create_test_session()
    session_id = session.id
    slot = :erlang.phash2(session_id, 64)

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

end
