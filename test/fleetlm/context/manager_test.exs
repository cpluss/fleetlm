defmodule Fleetlm.Context.ManagerTest do
  use Fleetlm.TestCase

  alias Fleetlm.Context.Manager
  alias Fleetlm.{Agent, Runtime}

  setup do
    {:ok, agent} =
      Agent.create(%{
        id: "context-agent",
        name: "Context Agent",
        origin_url: "http://localhost:4000",
        webhook_path: "/webhook",
        context_strategy: "last_n",
        context_strategy_config: %{"limit" => 5}
      })

    session = create_test_session("alice", agent.id)

    # Populate some messages
    {:ok, _} =
      Runtime.append_message(session.id, "alice", agent.id, "text", %{"text" => "one"}, %{})

    {:ok, _} =
      Runtime.append_message(session.id, agent.id, "alice", "text", %{"text" => "two"}, %{})

    {:ok, _} =
      Runtime.append_message(session.id, "alice", agent.id, "text", %{"text" => "three"}, %{})

    {:ok, message_list} = Runtime.get_messages(session.id, 0, 10)

    conversation = Runtime.get_conversation_metadata(session.id)

    on_exit(fn -> Fleetlm.Storage.AgentCache.clear_all() end)

    {:ok, agent: agent, session: session, conversation: conversation, messages: message_list}
  end

  test "build returns payload and snapshot", %{
    agent: agent,
    conversation: convo,
    messages: message_list
  } do
    snapshot =
      Enum.reduce(message_list, nil, fn message, acc ->
        {:ok, snapshot} = Manager.append_message(convo, acc, to_message_map(message), agent)
        snapshot
      end)

    payload = Manager.payload_from_snapshot(snapshot)
    assert %{messages: messages_payload, context: %{strategy: "last_n"}} = payload
    assert length(messages_payload) == 3
    assert snapshot.strategy_id == "last_n"
  end

  test "build reuses snapshot without errors", %{
    agent: agent,
    conversation: convo,
    messages: message_list
  } do
    snapshot =
      Enum.reduce(message_list, nil, fn msg, acc ->
        {:ok, snap} = Manager.append_message(convo, acc, to_message_map(msg), agent)
        snap
      end)

    last_map = to_message_map(List.last(message_list))

    {:ok, snapshot_after_append} =
      Manager.append_message(convo, snapshot, last_map, agent)

    assert snapshot_after_append.strategy_id == "last_n"
  end

  test "snapshot invalidated when strategy config changes", %{
    agent: agent,
    session: session,
    conversation: convo,
    messages: message_list
  } do
    snapshot =
      Enum.reduce(message_list, nil, fn msg, acc ->
        {:ok, snap} = Manager.append_message(convo, acc, to_message_map(msg), agent)
        snap
      end)

    {:ok, _updated} = Fleetlm.Agent.update(agent.id, %{context_strategy_config: %{"limit" => 1}})
    {:ok, reloaded} = Fleetlm.Agent.get(agent.id)

    {:ok, _} =
      Runtime.append_message(
        session.id,
        session.user_id,
        agent.id,
        "text",
        %{"text" => "new"},
        %{}
      )

    {:ok, new_messages} = Runtime.get_messages(session.id, 0, 10)
    new_message = List.last(new_messages)

    updated_convo = Runtime.get_conversation_metadata(session.id)

    {:ok, refreshed} =
      Manager.append_message(updated_convo, snapshot, to_message_map(new_message), reloaded)

    assert length(refreshed.pending_messages) <= 1
  end

  test "append_message emits telemetry", %{
    agent: agent,
    conversation: convo,
    messages: [first | _rest]
  } do
    handler_id = "context-build-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:fleetlm, :context, :build],
      fn event, measurements, metadata, _ ->
        send(self(), {:telemetry_event, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, _snapshot} = Manager.append_message(convo, nil, to_message_map(first), agent)

    assert_receive {:telemetry_event, [:fleetlm, :context, :build], %{duration: duration},
                    %{decision: :ok, strategy: "last_n"}},
                   500

    assert is_integer(duration) and duration >= 0
  end

  defp to_message_map(message) do
    if Map.has_key?(message, :__struct__), do: Map.from_struct(message), else: message
  end
end
