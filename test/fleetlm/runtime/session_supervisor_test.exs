defmodule Fleetlm.Runtime.SessionSupervisorTest do
  use Fleetlm.DataCase, async: false

  alias Fleetlm.Participants
  alias Fleetlm.Sessions
  alias Fleetlm.Runtime.SessionSupervisor

  setup do
    {:ok, alice} =
      Participants.upsert_participant(%{
        id: "user:alice",
        kind: "user",
        display_name: "Alice"
      })

    {:ok, bob} =
      Participants.upsert_participant(%{
        id: "user:bob",
        kind: "user",
        display_name: "Bob"
      })

    {:ok, session} =
      Sessions.start_session(%{
        initiator_id: alice.id,
        peer_id: bob.id
      })

    %{session: session}
  end

  test "ensure_started/1 returns the same pid for repeated calls", %{session: session} do
    assert {:ok, pid1} = SessionSupervisor.ensure_started(session.id)
    allow(pid1)
    assert {:ok, pid2} = SessionSupervisor.ensure_started(session.id)
    assert pid1 == pid2
  end

  defp allow(pid), do: allow_sandbox_access(pid)
end
