defmodule FleetlmWeb.MessageDuplicationTest do
  use FleetlmWeb.ChannelCase

  alias Fleetlm.Chat
  alias FleetlmWeb.{ConversationChannel, InboxChannel}

  describe "Message delivery" do
    setup do
      user_alice = "user:alice"
      user_bob = "user:bob"
      dm_key = Chat.generate_dm_key(user_alice, user_bob)

      {:ok, alice: user_alice, bob: user_bob, dm_key: dm_key}
    end

    test "ConversationChannel delivers a single message to subscribers", %{
      alice: alice,
      bob: bob,
      dm_key: dm_key
    } do
      {:ok, alice_socket} = connect(FleetlmWeb.UserSocket, %{"participant_id" => alice})

      {:ok, _reply, _} =
        subscribe_and_join(alice_socket, ConversationChannel, "conversation:" <> dm_key)

      {:ok, _message} = Chat.send_message(bob, alice, "Delivery test")

      assert_receive %Phoenix.Socket.Message{
                       event: "message",
                       payload: %{
                         "sender_id" => ^bob,
                         "recipient_id" => ^alice,
                         "text" => "Delivery test"
                       }
                     },
                     1_000

      refute_receive %Phoenix.Socket.Message{event: "message"}, 200
    end

    test "InboxChannel emits a single inbox_delta per flush", %{alice: alice, bob: bob} do
      {:ok, alice_socket} = connect(FleetlmWeb.UserSocket, %{"participant_id" => alice})

      {:ok, _reply, _inbox_socket} =
        subscribe_and_join(alice_socket, InboxChannel, "inbox:" <> alice)

      {:ok, _message} = Chat.send_message(bob, alice, "Inbox delivery test")

      assert_receive %Phoenix.Socket.Message{
                       event: "tick",
                       payload: %{
                         "updates" => [%{"last_message_text" => "Inbox delivery test"} = update]
                       }
                     },
                     1_000

      assert update["last_sender_id"] == bob
      refute_receive %Phoenix.Socket.Message{event: "tick"}, 200
    end

    test "publish_dm_activity emits one event per participant", %{
      alice: alice,
      bob: bob,
      dm_key: dm_key
    } do
      Phoenix.PubSub.subscribe(Fleetlm.PubSub, "inbox:" <> alice)
      Phoenix.PubSub.subscribe(Fleetlm.PubSub, "inbox:" <> bob)

      {:ok, _} = Fleetlm.Chat.InboxSupervisor.ensure_started(alice)
      {:ok, _} = Fleetlm.Chat.InboxSupervisor.ensure_started(bob)
      :ok = Fleetlm.Chat.InboxServer.flush(alice)
      :ok = Fleetlm.Chat.InboxServer.flush(bob)

      {:ok, _message} = Chat.send_message(bob, alice, "PubSub activity test")

      assert_receive {:inbox_delta, %{updates: updates_a}}, 1_000
      assert Enum.any?(updates_a, &(&1["dm_key"] == dm_key))

      assert_receive {:inbox_delta, %{updates: updates_b}}, 1_000
      assert Enum.any?(updates_b, &(&1["dm_key"] == dm_key))

      refute_receive {:inbox_delta, _}, 200
    end

    test "Both participants receive exactly one copy of each message", %{
      alice: alice,
      bob: bob,
      dm_key: dm_key
    } do
      {:ok, alice_socket} = connect(FleetlmWeb.UserSocket, %{"participant_id" => alice})
      {:ok, bob_socket} = connect(FleetlmWeb.UserSocket, %{"participant_id" => bob})

      {:ok, _reply, _} =
        subscribe_and_join(alice_socket, ConversationChannel, "conversation:" <> dm_key)

      {:ok, _reply, _} =
        subscribe_and_join(bob_socket, ConversationChannel, "conversation:" <> dm_key)

      {:ok, _message} = Chat.send_message(alice, bob, "One copy each")

      assert_receive %Phoenix.Socket.Message{
                       event: "message",
                       payload: %{"sender_id" => ^alice, "text" => "One copy each"}
                     },
                     1_000

      assert_receive %Phoenix.Socket.Message{
                       event: "message",
                       payload: %{"sender_id" => ^alice, "text" => "One copy each"}
                     },
                     1_000

      refute_receive %Phoenix.Socket.Message{event: "message"}, 200
    end
  end
end
