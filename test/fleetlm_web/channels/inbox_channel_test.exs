defmodule FleetlmWeb.InboxChannelTest do
  use FleetlmWeb.ChannelCase

  alias Fleetlm.Conversation.Participants
  alias Fleetlm.Runtime.Gateway
  alias Fleetlm.Conversation
  alias FleetlmWeb.InboxChannel

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

    {:ok, _} =
      Gateway.append_message(session.id, %{
        sender_id: "user:alice",
        kind: "text",
        content: %{text: "hello"}
      })

    %{session: session}
  end

  test "joining returns inbox snapshot" do
    {:ok, socket} = connect(FleetlmWeb.UserSocket, %{"participant_id" => "user:alice"})

    {:ok, %{conversations: conversations}, _socket} =
      subscribe_and_join(socket, InboxChannel, "inbox:user:alice")

    assert [%{"session_id" => _}] = conversations
  end

  test "non owner cannot join" do
    {:ok, socket} = connect(FleetlmWeb.UserSocket, %{"participant_id" => "user:bob"})

    assert {:error, %{reason: "unauthorized"}} =
             subscribe_and_join(socket, InboxChannel, "inbox:user:alice")
  end
end
