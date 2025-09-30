defmodule FleetLM.Storage.APITest do
  use ExUnit.Case, async: false

  alias FleetLM.Storage.API
  alias FleetLM.Storage.Model.{Session, Message}
  alias FleetLM.Storage.SlotLogServer
  alias Fleetlm.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Fleetlm.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Fleetlm.Repo, {:shared, self()})

    temp_dir =
      System.tmp_dir!()
      |> Path.join("fleetlm_slot_logs_test_#{System.unique_integer([:positive])}")

    File.rm_rf(temp_dir)
    File.mkdir_p!(temp_dir)

    previous_dir = Application.fetch_env(:fleetlm, :slot_log_dir)
    Application.put_env(:fleetlm, :slot_log_dir, temp_dir)

    on_exit(fn ->
      case previous_dir do
        {:ok, dir} -> Application.put_env(:fleetlm, :slot_log_dir, dir)
        :error -> Application.delete_env(:fleetlm, :slot_log_dir)
      end

      File.rm_rf(temp_dir)
    end)

    :ok
  end

  test "get_messages returns entries from disk log before they are persisted" do
    session_id = new_session_id()
    slot = slot_for_session(session_id)
    {:ok, _pid} = start_supervised({SlotLogServer, slot})

    insert_session!(session_id, slot)

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
    session_id = new_session_id()
    slot = slot_for_session(session_id)
    {:ok, _pid} = start_supervised({SlotLogServer, slot})

    insert_session!(session_id, slot)

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
    session_id = new_session_id()
    slot = slot_for_session(session_id)
    {:ok, _pid} = start_supervised({SlotLogServer, slot})

    insert_session!(session_id, slot)

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

  defp insert_session!(session_id, shard_key) do
    Repo.insert!(%Session{
      id: session_id,
      sender_id: "sender",
      recipient_id: "recipient",
      status: "active",
      metadata: %{},
      shard_key: shard_key
    })
  end

  defp new_session_id do
    "session-" <> Integer.to_string(System.unique_integer([:positive]))
  end

  defp slot_for_session(session_id) do
    :erlang.phash2(session_id, Application.get_env(:fleetlm, :num_storage_slots, 64))
  end
end
