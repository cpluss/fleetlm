defmodule Fleetlm.Context.Strategies.LastNTest do
  use Fleetlm.TestCase

  alias Fleetlm.Context.Strategies.LastN
  alias Fleetlm.Context.Manager
  alias Fleetlm.{Agent, Runtime}

  setup do
    {:ok, agent} =
      Agent.create(%{
        id: "strategy-last-n",
        name: "Strategy Agent",
        origin_url: "http://localhost:4000",
        webhook_path: "/webhook",
        context_strategy: "last_n",
        context_strategy_config: %{"limit" => 3}
      })

    session = create_test_session("user", agent.id)

    for idx <- 1..5 do
      {:ok, _} =
        Runtime.append_message(
          session.id,
          "user",
          agent.id,
          "text",
          %{"text" => "message-#{idx}"},
          %{}
        )
    end

    {:ok, messages} = Runtime.get_messages(session.id, 0, 10)
    {:ok, agent: agent, messages: messages}
  end

  test "append_message trims to configured limit", %{messages: messages} do
    snapshot =
      Enum.reduce(messages, nil, fn message, acc ->
        message_map =
          if Map.has_key?(message, :__struct__), do: Map.from_struct(message), else: message

        {:ok, snapshot} = LastN.append_message(acc, message_map, %{"limit" => 3}, [])
        snapshot
      end)

    payload = Manager.payload_from_snapshot(snapshot)
    assert length(payload.messages) == 3

    extracted =
      Enum.map(payload.messages, fn msg ->
        content = Map.get(msg, "content") || Map.get(msg, :content) || %{}
        content["text"] || content[:text]
      end)

    assert extracted ==
             Enum.map(Enum.slice(messages, -3, 3), fn msg -> msg.content["text"] end)

    assert snapshot.metadata[:pending_queue]
    assert :queue.is_queue(snapshot.metadata[:pending_queue])
  end

  test "append_message uses default limit" do
    assert {:ok, snapshot} =
             LastN.append_message(nil, %{"seq" => 1, "content" => %{}}, %{}, [])

    payload = Manager.payload_from_snapshot(snapshot)
    assert length(payload.messages) == 1
  end

  test "append_message trims when token budget exceeded" do
    config = %{"limit" => 5, "max_tokens" => 1}

    snapshot =
      Enum.reduce(1..4, nil, fn seq, acc ->
        message = %{"seq" => seq, "content" => %{"text" => String.duplicate("x", 8)}}

        case LastN.append_message(acc, message, config, []) do
          {:ok, snap} -> snap
          other -> flunk("unexpected result: #{inspect(other)}")
        end
      end)

    payload = Manager.payload_from_snapshot(snapshot)
    assert length(payload.messages) <= 5
    assert snapshot.token_count <= 1
  end
end
