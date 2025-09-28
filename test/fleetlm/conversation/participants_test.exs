defmodule Fleetlm.Conversation.ParticipantsTest do
  use Fleetlm.DataCase

  alias Fleetlm.Conversation.Participants
  alias Fleetlm.Conversation.Participant

  describe "upsert_participant/1" do
    test "creates a participant" do
      assert {:ok, %Participant{id: "user:test", kind: "user"}} =
               Participants.upsert_participant(%{
                 id: "user:test",
                 kind: "user",
                 display_name: "Test User"
               })

      assert %Participant{} = Participants.get_participant!("user:test")
    end

    test "updates existing participant" do
      {:ok, participant} =
        Participants.upsert_participant(%{
          id: "agent:bot",
          kind: "agent",
          display_name: "Bot"
        })

      assert {:ok, %Participant{display_name: "Bot v2"}} =
               Participants.upsert_participant(%{
                 id: participant.id,
                 kind: "agent",
                 display_name: "Bot v2"
               })
    end
  end

  describe "list_participants/1" do
    test "filters by kind" do
      Participants.upsert_participant(%{id: "user:one", kind: "user", display_name: "One"})
      Participants.upsert_participant(%{id: "agent:two", kind: "agent", display_name: "Two"})

      assert [%Participant{id: "agent:two"}] = Participants.list_participants(kind: "agent")
    end
  end
end
