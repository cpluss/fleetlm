defmodule Fleetlm.Runtime.GatewayTest do
  use Fleetlm.DataCase

  alias Fleetlm.Runtime.Gateway
  alias Fleetlm.Runtime.Router
  alias Fleetlm.Conversation.Participants
  alias Fleetlm.Conversation

  setup do
    {:ok, _} =
      Participants.upsert_participant(%{
        id: "user:alice",
        kind: "user",
        display_name: "Alice"
      })

    {:ok, _} =
      Participants.upsert_participant(%{
        id: "agent:bot",
        kind: "agent",
        display_name: "Bot"
      })

    {:ok, session} =
      Conversation.start_session(%{
        initiator_id: "user:alice",
        peer_id: "agent:bot"
      })

    handler_id = "gateway-test-" <> Integer.to_string(System.unique_integer([:positive]))

    :telemetry.attach(
      handler_id,
      [:fleetlm, :session, :append, :stop],
      fn event, meas, meta, pid ->
        send(pid, {:telemetry_event, event, meas, meta})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:ok, session: session}
  end

  test "append_message emits telemetry spans", %{session: session} do
    assert {:ok, _message} =
             Gateway.append_message(session.id, %{
               sender_id: session.initiator_id,
               kind: "text",
               content: %{text: "hi"}
             })

    assert_receive {
                     :telemetry_event,
                     [:fleetlm, :session, :append, :stop],
                     measurements,
                     metadata
                   },
                   1000

    assert is_integer(measurements.duration)
    assert metadata[:strategy]
    assert metadata[:kind] == "text"
  end

  test "append_message is idempotent for repeated idempotency key", %{session: session} do
    attrs = %{
      sender_id: session.initiator_id,
      kind: "text",
      content: %{text: "ping"},
      idempotency_key: "dup-key"
    }

    assert {:ok, message1} = Gateway.append_message(session.id, attrs)
    assert {:ok, message2} = Gateway.append_message(session.id, attrs)

    assert message1.id == message2.id
    assert :ok = Router.await_persistence(session.id, message1.id)
  end
end
