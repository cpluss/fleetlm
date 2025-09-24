defmodule FleetlmWeb.FixVerificationTest do
  @moduledoc """
  Test suite to verify that the message duplication fix is working correctly.

  This test focuses on verifying the current state after the fix attempts,
  and can be used to validate when the duplication issue is fully resolved.
  """
  use FleetlmWeb.ChannelCase

  alias Fleetlm.Chat
  alias Fleetlm.Chat.{InboxServer, InboxSupervisor}
  alias FleetlmWeb.ConversationChannel
  alias FleetlmWeb.InboxChannel

  describe "Fix Verification Tests" do
    setup do
      user_alice = "user:alice"
      user_bob = "user:bob"
      dm_key = Chat.generate_dm_key(user_alice, user_bob)

      {:ok, alice: user_alice, bob: user_bob, dm_key: dm_key}
    end

    test "ConversationChannel should receive messages exactly once (post-fix verification)", %{
      alice: alice,
      bob: bob,
      dm_key: dm_key
    } do
      # Alice joins the conversation channel
      {:ok, alice_socket} = connect(FleetlmWeb.UserSocket, %{"participant_id" => alice})

      {:ok, _reply, _alice_socket} =
        subscribe_and_join(alice_socket, ConversationChannel, "conversation:" <> dm_key)

      # Bob sends a message to Alice
      {:ok, _message} = Chat.send_message(bob, alice, "Fix verification test message")

      # Alice's channel should receive the message exactly once
      assert_receive %Phoenix.Socket.Message{
                       event: "message",
                       payload: %{
                         "sender_id" => ^bob,
                         "recipient_id" => ^alice,
                         "text" => "Fix verification test message"
                       }
                     },
                     1000

      # CRITICAL: No duplicate should be received
      # If this fails, the fix is not complete
      refute_receive %Phoenix.Socket.Message{event: "message"}, 500
    end

    test "InboxChannel should receive updates exactly once (post-fix verification)", %{
      alice: alice,
      bob: bob
    } do
      # Alice joins her inbox channel
      {:ok, alice_socket} = connect(FleetlmWeb.UserSocket, %{"participant_id" => alice})

      {:ok, _reply, _alice_socket} =
        subscribe_and_join(alice_socket, InboxChannel, "inbox:" <> alice)

      # Bob sends a message to Alice
      {:ok, _message} = Chat.send_message(bob, alice, "Fix verification inbox test")

      # Alice's inbox should receive exactly one update
      # Note: The data structure may have changed, so we need to match the current format
      assert_receive %Phoenix.Socket.Message{
                       event: "tick",
                       payload: %{
                         "updates" => [
                           %{
                             "dm_key" => _dm_key,
                             "last_message_text" => "Fix verification inbox test",
                             "last_sender_id" => ^bob
                           }
                         ]
                       }
                     },
                     1000

      # CRITICAL: No duplicate update should be received
      # If this fails, the inbox fix is not complete
      refute_receive %Phoenix.Socket.Message{event: "tick"}, 500
    end

    test "verify PubSub events are sent only once per message (architectural verification)", %{
      alice: alice,
      bob: bob
    } do
      # Subscribe directly to PubSub to monitor event frequency
      Phoenix.PubSub.subscribe(Fleetlm.PubSub, "inbox:" <> alice)

      {:ok, _} = InboxSupervisor.ensure_started(alice)
      {:ok, _} = InboxSupervisor.ensure_started(bob)
      :ok = InboxServer.flush(alice)
      :ok = InboxServer.flush(bob)

      # Send a message
      {:ok, _message} = Chat.send_message(bob, alice, "PubSub verification test")

      # Should receive exactly ONE inbox_delta event for Alice
      assert_receive {:inbox_delta, %{updates: updates}}, 1000
      assert length(updates) == 1
      assert Enum.at(updates, 0)["last_message_text"] == "PubSub verification test"

      # CRITICAL: Should NOT receive a duplicate inbox_delta event
      # If this fails, the Events.publish_dm_activity is still being called multiple times
      refute_receive {:inbox_delta, _}, 500
    end

    test "message count verification - both participants get single notifications", %{
      alice: alice,
      bob: bob,
      dm_key: dm_key
    } do
      # Both Alice and Bob join the conversation
      {:ok, alice_socket} = connect(FleetlmWeb.UserSocket, %{"participant_id" => alice})
      {:ok, bob_socket} = connect(FleetlmWeb.UserSocket, %{"participant_id" => bob})

      {:ok, _reply, _alice_socket} =
        subscribe_and_join(alice_socket, ConversationChannel, "conversation:" <> dm_key)

      {:ok, _reply, _bob_socket} =
        subscribe_and_join(bob_socket, ConversationChannel, "conversation:" <> dm_key)

      # Alice sends a message
      {:ok, _message} = Chat.send_message(alice, bob, "Single notification test")

      # Alice should receive her own message exactly once
      assert_receive %Phoenix.Socket.Message{
                       event: "message",
                       payload: %{"sender_id" => ^alice, "text" => "Single notification test"}
                     },
                     1000

      # Bob should receive the message exactly once
      assert_receive %Phoenix.Socket.Message{
                       event: "message",
                       payload: %{"sender_id" => ^alice, "text" => "Single notification test"}
                     },
                     1000

      # CRITICAL: Neither should receive duplicates
      refute_receive %Phoenix.Socket.Message{event: "message"}, 500
      refute_receive %Phoenix.Socket.Message{event: "message"}, 500
    end
  end
end
