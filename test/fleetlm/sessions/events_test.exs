defmodule Fleetlm.Sessions.EventsTest do
  use Fleetlm.DataCase, async: false

  alias Fleetlm.Participants
  alias Fleetlm.Sessions
  alias Fleetlm.Sessions.{Cache, SessionSupervisor}

  setup do
    :ok = Cache.reset()
    on_exit(fn -> Cache.reset() end)

    {:ok, alice} = ensure_participant("user:alice")
    {:ok, bob} = ensure_participant("user:bob")

    {:ok, session} =
      Sessions.start_session(%{
        initiator_id: alice.id,
        peer_id: bob.id
      })

    Phoenix.PubSub.subscribe(Fleetlm.PubSub, "session:" <> session.id)
    Phoenix.PubSub.subscribe(Fleetlm.PubSub, "inbox:" <> alice.id)
    Phoenix.PubSub.subscribe(Fleetlm.PubSub, "inbox:" <> bob.id)

    {:ok, _} = SessionSupervisor.ensure_started(session.id)

    %{session: session, alice: alice, bob: bob}
  end

  test "appending messages emits session and inbox broadcasts", %{session: session, alice: alice} do
    {:ok, message} =
      Sessions.append_message(session.id, %{
        sender_id: alice.id,
        kind: "text",
        content: %{text: "Hi Bob"}
      })

    assert_receive {:session_message, payload}, 500
    assert payload["id"] == message.id
    assert payload["session_id"] == session.id
    assert payload["content"]["text"] == "Hi Bob"

    Enum.each([alice.id, session.peer_id], fn _participant_id ->
      assert_receive {:inbox_snapshot, snapshot}, 500
      assert Enum.any?(snapshot, &(&1["session_id"] == session.id))
    end)
  end

  defp ensure_participant(id, kind \\ "user") do
    Participants.upsert_participant(%{
      id: id,
      kind: kind,
      display_name: id
    })
  end
end
