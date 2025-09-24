defmodule Fleetlm.ChatIntegrationTest do
  use FleetlmWeb.ChannelCase

  alias Fleetlm.Chat
  alias Fleetlm.ChatCase.Client

  describe "multi-participant chat flows" do
    setup do
      {:ok, alice} = Client.start("user:alice")
      {:ok, alice, _} = Client.join_inbox(alice)

      {:ok, bob} = Client.start("user:bob")
      {:ok, bob, _} = Client.join_inbox(bob)

      {:ok, carol} = Client.start("user:carol")
      {:ok, carol, _} = Client.join_inbox(carol)

      {:ok, alice: alice, bob: bob, carol: carol}
    end

    test "direct messages fan out across participants and maintain inbox state", %{
      alice: alice,
      bob: bob,
      carol: carol
    } do
      {:ok, alice, reply_ab} = Client.join_conversation(alice, bob.participant_id)
      dm_key_ab = reply_ab["dm_key"]
      assert reply_ab["messages"] == []

      {:ok, bob, reply_ba} = Client.join_conversation(bob, {:dm_key, dm_key_ab})
      assert reply_ba["dm_key"] == dm_key_ab
      assert reply_ba["messages"] == []

      {:ok, _event} = Client.send_message(alice, bob.participant_id, "Ping Bob")

      assert {:ok, msg_for_alice} = Client.wait_for_message(alice, dm_key_ab)
      assert msg_for_alice["sender_id"] == alice.participant_id
      assert msg_for_alice["recipient_id"] == bob.participant_id
      assert msg_for_alice["text"] == "Ping Bob"

      assert {:ok, msg_for_bob} = Client.wait_for_message(bob, dm_key_ab)
      assert msg_for_bob["sender_id"] == alice.participant_id
      assert msg_for_bob["recipient_id"] == bob.participant_id
      assert msg_for_bob["text"] == "Ping Bob"

      :ok = Client.flush_inbox(bob)
      assert {:ok, updates_bob} = Client.wait_for_inbox_updates(bob, attempts: 5)
      update_bob = Client.find_inbox_update(updates_bob, dm_key_ab)
      assert update_bob["dm_key"] == dm_key_ab
      assert update_bob["last_sender_id"] == alice.participant_id
      assert update_bob["unread_count"] == 1

      :ok = Client.flush_inbox(alice)
      assert {:ok, updates_alice} = Client.wait_for_inbox_updates(alice, attempts: 5)
      update_alice = Client.find_inbox_update(updates_alice, dm_key_ab)
      assert update_alice["dm_key"] == dm_key_ab
      assert update_alice["last_sender_id"] == alice.participant_id
      assert update_alice["unread_count"] == 0

      {:ok, _reply_event} =
        Client.send_message(bob, alice.participant_id, "Hi Alice", %{"mood" => "excited"})

      assert {:ok, msg_for_bob_again} =
               Client.wait_for_message(bob, dm_key_ab,
                 attempts: 5,
                 match: fn payload -> payload["text"] == "Hi Alice" end
               )

      assert msg_for_bob_again["sender_id"] == bob.participant_id
      assert msg_for_bob_again["recipient_id"] == alice.participant_id
      assert msg_for_bob_again["text"] == "Hi Alice"

      assert {:ok, msg_for_alice_again} =
               Client.wait_for_message(alice, dm_key_ab,
                 attempts: 5,
                 match: fn payload -> payload["text"] == "Hi Alice" end
               )

      assert msg_for_alice_again["metadata"] == %{"mood" => "excited"}
      assert msg_for_alice_again["text"] == "Hi Alice"

      :ok = Client.flush_inbox(alice)

      assert {:ok, update_alice_again} =
               Client.wait_for_inbox_update(alice, dm_key_ab,
                 attempts: 8,
                 match: fn update -> update["last_sender_id"] == bob.participant_id end
               )

      assert update_alice_again["unread_count"] == 1

      assert :ok = Chat.mark_read(dm_key_ab, alice.participant_id)
      :ok = Client.flush_inbox(alice)

      assert {:ok, update_after_read} =
               Client.wait_for_inbox_update(alice, dm_key_ab,
                 attempts: 8,
                 match: fn update -> update["unread_count"] == 0 end
               )

      assert update_after_read["unread_count"] == 0

      {:ok, alice, reply_broadcast_alice} = Client.join_conversation(alice, :broadcast)
      assert reply_broadcast_alice["messages"] == []

      {:ok, carol, reply_broadcast_carol} = Client.join_conversation(carol, :broadcast)
      assert reply_broadcast_carol["dm_key"] == "broadcast"

      {:ok, _broadcast_event} = Client.send_broadcast(alice, "System ping")

      assert {:ok, broadcast_for_alice} = Client.wait_for_message(alice, "broadcast")
      assert broadcast_for_alice["sender_id"] == alice.participant_id
      assert broadcast_for_alice["text"] == "System ping"

      assert {:ok, broadcast_for_carol} = Client.wait_for_message(carol, "broadcast")
      assert broadcast_for_carol["sender_id"] == alice.participant_id
      assert broadcast_for_carol["text"] == "System ping"
    end

    test "aggregates inbox updates and preserves history across conversations", %{
      alice: alice,
      bob: bob,
      carol: carol
    } do
      dm_ac = Client.dm_key(alice, carol.participant_id)
      dm_bc = Client.dm_key(bob, carol.participant_id)

      {:ok, _} = Client.send_message(alice, carol.participant_id, "Hello Carol")
      {:ok, _} = Client.send_message(bob, carol.participant_id, "Hey there")

      :ok = Client.flush_inbox(carol)
      assert {:ok, updates_carol} = Client.wait_for_inbox_updates(carol, attempts: 5)
      assert length(updates_carol) == 2

      update_ac = Client.find_inbox_update(updates_carol, dm_ac)
      assert update_ac
      assert update_ac["last_sender_id"] == alice.participant_id
      assert update_ac["unread_count"] == 1

      update_bc = Client.find_inbox_update(updates_carol, dm_bc)
      assert update_bc
      assert update_bc["last_sender_id"] == bob.participant_id
      assert update_bc["unread_count"] == 1

      {:ok, carol, reply_ac} = Client.join_conversation(carol, {:dm_key, dm_ac})
      assert Enum.map(reply_ac["messages"], & &1["text"]) == ["Hello Carol"]

      {:ok, carol, reply_bc} = Client.join_conversation(carol, {:dm_key, dm_bc})
      assert Enum.map(reply_bc["messages"], & &1["text"]) == ["Hey there"]

      {:ok, _} = Client.send_message(alice, carol.participant_id, "Follow up")

      assert {:ok, msg_for_carol} = Client.wait_for_message(carol, dm_ac, attempts: 5)
      assert msg_for_carol["sender_id"] == alice.participant_id
      assert msg_for_carol["text"] == "Follow up"

      :ok = Client.flush_inbox(carol)

      assert {:ok, update_after_follow_up} =
               Client.wait_for_inbox_update(carol, dm_ac,
                 attempts: 8,
                 match: fn update -> update["last_message_text"] == "Follow up" end
               )

      assert update_after_follow_up["unread_count"] == 2

      assert :ok = Chat.mark_read(dm_ac, carol.participant_id)
      :ok = Client.flush_inbox(carol)

      assert {:ok, update_after_read} =
               Client.wait_for_inbox_update(carol, dm_ac,
                 attempts: 8,
                 match: fn update -> update["unread_count"] == 0 end
               )

      assert update_after_read["unread_count"] == 0
    end

    test "delivers queued messages after participant reconnects", %{alice: alice, bob: bob} do
      {:ok, alice, reply_ab} = Client.join_conversation(alice, bob.participant_id)
      dm_key_ab = reply_ab["dm_key"]

      {:ok, bob, _reply_ba} = Client.join_conversation(bob, {:dm_key, dm_key_ab})

      {:ok, _} = Client.send_message(alice, bob.participant_id, "Initial hello")

      assert {:ok, _msg_for_alice} =
               Client.wait_for_message(alice, dm_key_ab,
                 attempts: 5,
                 match: fn payload -> payload["text"] == "Initial hello" end
               )

      assert {:ok, _msg_for_bob} =
               Client.wait_for_message(bob, dm_key_ab,
                 attempts: 5,
                 match: fn payload -> payload["text"] == "Initial hello" end
               )

      assert {:ok, bob} = Client.close_conversation(bob, dm_key_ab)
      assert {:ok, bob} = Client.close_inbox(bob)

      {:ok, _} = Client.send_message(alice, bob.participant_id, "Are you there?")

      {:ok, bob_reconnect} = Client.start(bob.participant_id)
      {:ok, bob_reconnect, inbox_reply} = Client.join_inbox(bob_reconnect)
      snapshot_entry = Client.find_inbox_update(inbox_reply["conversations"], dm_key_ab)
      assert snapshot_entry
      assert snapshot_entry["unread_count"] >= 1

      {:ok, bob_reconnect, join_reply} =
        Client.join_conversation(bob_reconnect, {:dm_key, dm_key_ab})

      messages = join_reply["messages"]
      assert Enum.any?(messages, fn message -> message["text"] == "Are you there?" end)
      assert List.last(messages)["text"] == "Are you there?"

      {:ok, _} = Client.send_message(alice, bob.participant_id, "Welcome back")

      assert {:ok, live_message} =
               Client.wait_for_message(bob_reconnect, dm_key_ab,
                 attempts: 8,
                 match: fn payload -> payload["text"] == "Welcome back" end
               )

      assert live_message["text"] == "Welcome back"
    end

    test "debounced inbox updates consolidate bursts", %{alice: alice, bob: bob} do
      {:ok, alice, reply_ab} = Client.join_conversation(alice, bob.participant_id)
      dm_key_ab = reply_ab["dm_key"]

      {:ok, _} = Client.send_message(alice, bob.participant_id, "Burst one")
      {:ok, _} = Client.send_message(alice, bob.participant_id, "Burst two")

      assert {:ok, update_bob} =
               Client.wait_for_inbox_update(bob, dm_key_ab,
                 attempts: 8,
                 match: fn update -> update["unread_count"] == 2 end
               )

      assert update_bob["last_message_text"] == "Burst two"
    end

    test "conversation history respects tail limit", %{alice: alice, bob: bob} do
      dm_key_ab = Client.dm_key(alice, bob.participant_id)

      for n <- 1..45 do
        {:ok, _} = Client.send_message(alice, bob.participant_id, "message #{n}")
      end

      {:ok, _bob_after_join, join_reply} = Client.join_conversation(bob, {:dm_key, dm_key_ab})
      messages = join_reply["messages"]
      assert length(messages) == 40

      expected_texts = Enum.map(6..45, &"message #{&1}")
      assert Enum.map(messages, & &1["text"]) == expected_texts
      refute Enum.any?(messages, fn message -> message["text"] == "message 5" end)
    end
  end
end
