defmodule FleetlmWeb.ChatChannelBehaviourTest do
  use FleetlmWeb.ChannelCase

  @moduletag skip: "Legacy chat runtime pending replacement"

  alias Fleetlm.ChatCase.Client

  describe "behavioural delivery guarantees" do
    test "direct messages deliver a single copy per participant" do
      {:ok, alice} = Client.start("user:alice")
      {:ok, bob} = Client.start("user:bob")

      {:ok, alice, reply_ab} = Client.join_conversation(alice, bob.participant_id)
      dm_key = reply_ab["dm_key"]
      {:ok, bob, _} = Client.join_conversation(bob, {:dm_key, dm_key})

      {:ok, _event} = Client.send_message(alice, bob.participant_id, "One copy only")

      assert {:ok, message_for_alice} =
               Client.wait_for_message(alice, dm_key, attempts: 5)

      assert message_for_alice["sender_id"] == alice.participant_id
      assert message_for_alice["recipient_id"] == bob.participant_id
      assert message_for_alice["text"] == "One copy only"

      assert {:error, :timeout} =
               Client.wait_for_message(alice, dm_key, attempts: 1, timeout: 50)

      assert {:ok, message_for_bob} =
               Client.wait_for_message(bob, dm_key, attempts: 5)

      assert message_for_bob["sender_id"] == alice.participant_id
      assert message_for_bob["recipient_id"] == bob.participant_id
      assert message_for_bob["text"] == "One copy only"

      assert {:error, :timeout} =
               Client.wait_for_message(bob, dm_key, attempts: 1, timeout: 50)
    end

    test "inbox ticks emit a single aggregated update per flush" do
      {:ok, alice} = Client.start("user:alice")
      {:ok, alice, _snapshot} = Client.join_inbox(alice)
      {:ok, bob} = Client.start("user:bob")

      {:ok, _event} = Client.send_message(bob, alice.participant_id, "Inbox once")
      :ok = Client.flush_inbox(alice)

      dm_key = Client.dm_key(alice, bob.participant_id)

      assert {:ok, updates} = Client.wait_for_inbox_updates(alice, attempts: 5)
      update = Client.find_inbox_update(updates, dm_key)
      assert update
      assert update["last_sender_id"] == bob.participant_id
      assert update["last_message_text"] == "Inbox once"
      assert update["unread_count"] == 1

      assert {:error, :timeout} =
               Client.wait_for_inbox_updates(alice, attempts: 1, timeout: 50)
    end

    test "late conversation joins replay backlog once without duplicates" do
      {:ok, alice} = Client.start("user:alice")
      {:ok, alice, reply_ab} = Client.join_conversation(alice, "user:bob")
      dm_key = reply_ab["dm_key"]

      {:ok, bob} = Client.start("user:bob")

      {:ok, _event} = Client.send_message(bob, alice.participant_id, "Queued for join")

      assert {:ok, message_for_alice} =
               Client.wait_for_message(alice, dm_key, attempts: 5)

      assert message_for_alice["sender_id"] == bob.participant_id
      assert message_for_alice["text"] == "Queued for join"

      {:ok, bob, join_reply} = Client.join_conversation(bob, {:dm_key, dm_key})

      texts = Enum.map(join_reply["messages"], & &1["text"])
      assert texts == ["Queued for join"]

      assert {:error, :timeout} =
               Client.wait_for_message(bob, dm_key, attempts: 1, timeout: 50)
    end
  end

  describe "scaling fan-out" do
    test "single participant receives 100 concurrent inbound DMs without duplicate ticks" do
      total_participants = 100

      {:ok, recipient} = Client.start("user:recipient")
      {:ok, recipient, _snapshot} = Client.join_inbox(recipient)

      dm_messages =
        Enum.map(1..total_participants, fn idx ->
          sender_id = "user:sender#{idx}"
          message_text = "bulk message #{idx}"

          {:ok, sender} = Client.start(sender_id)
          {:ok, sender, _reply} = Client.join_conversation(sender, recipient.participant_id)

          {:ok, _event} = Client.send_message(sender, recipient.participant_id, message_text)
          dm_key = Client.dm_key(sender, recipient.participant_id)

          assert {:ok, self_message} = Client.wait_for_message(sender, dm_key, attempts: 5)
          assert self_message["sender_id"] == sender.participant_id
          assert self_message["text"] == message_text

          assert {:error, :timeout} =
                   Client.wait_for_message(sender, dm_key, attempts: 1, timeout: 50)

          {dm_key, sender, message_text}
        end)

      :ok = Client.flush_inbox(recipient)

      assert {:ok, updates} = gather_inbox_updates(recipient, total_participants)
      assert length(updates) == total_participants

      expected_dm_keys = dm_messages |> Enum.map(&elem(&1, 0)) |> MapSet.new()

      Enum.each(updates, fn update ->
        assert MapSet.member?(expected_dm_keys, update["dm_key"])
        assert update["unread_count"] == 1
        refute Map.has_key?(update, "text")
        refute Map.has_key?(update, "metadata")
      end)

      assert {:error, :timeout} =
               Client.wait_for_inbox_updates(recipient, attempts: 1, timeout: 50)

      Enum.each(dm_messages, fn {dm_key, _sender, _message_text} ->
        assert :ok = Fleetlm.Chat.mark_read(dm_key, recipient.participant_id)
      end)

      :ok = Client.flush_inbox(recipient)

      assert {:ok, cleared_updates} = gather_inbox_updates(recipient, total_participants)

      Enum.each(cleared_updates, fn update ->
        assert update["unread_count"] == 0
      end)

      assert {:error, :timeout} =
               Client.wait_for_inbox_updates(recipient, attempts: 1, timeout: 50)

      recipient =
        Enum.reduce(dm_messages, recipient, fn {dm_key, sender, message_text}, acc ->
          {:ok, acc, reply} = Client.join_conversation(acc, {:dm_key, dm_key})

          texts = Enum.map(reply["messages"], & &1["text"])
          assert texts == [message_text]

          assert Enum.any?(reply["messages"], fn message ->
                   message["sender_id"] == sender.participant_id and
                     message["text"] == message_text
                 end)

          assert {:error, :timeout} =
                   Client.wait_for_message(acc, dm_key, attempts: 1, timeout: 50)

          acc
        end)

      assert %Client{} = recipient
    end
  end

  describe "resilience under churn" do
    test "rapid reconnect churn does not drop or duplicate inbox activity" do
      recipient_id = "user:recipient-churn"
      sender_count = 20
      cycles = 2

      {:ok, recipient} = Client.start(recipient_id)
      {:ok, recipient, _snapshot} = Client.join_inbox(recipient)

      {_recipient, dm_keys} =
        Enum.reduce(1..sender_count, {recipient, %{}}, fn idx, {rec, acc_map} ->
          sender_id = "user:churn#{idx}"

          Enum.reduce(1..cycles, {rec, acc_map}, fn cycle, {rec_acc, map_acc} ->
            {:ok, sender} = Client.start(sender_id)
            {:ok, sender, reply} = Client.join_conversation(sender, rec_acc.participant_id)
            dm_key = reply["dm_key"]

            {rec_acc, map_acc} =
              case Map.fetch(map_acc, sender_id) do
                :error ->
                  {:ok, rec_acc, _} = Client.join_conversation(rec_acc, {:dm_key, dm_key})
                  {rec_acc, Map.put(map_acc, sender_id, dm_key)}

                {:ok, existing_dm_key} ->
                  assert existing_dm_key == dm_key
                  {rec_acc, map_acc}
              end

            text = "churn message #{idx}-#{cycle}"

            {:ok, _event} = Client.send_message(sender, rec_acc.participant_id, text)

            assert {:ok, _self_message} =
                     Client.wait_for_message(sender, dm_key,
                       attempts: 5,
                       match: fn payload -> payload["text"] == text end
                     )

            assert {:ok, live_message} =
                     Client.wait_for_message(rec_acc, dm_key,
                       attempts: 5,
                       match: fn payload -> payload["text"] == text end
                     )

            assert live_message["sender_id"] == sender.participant_id

            :ok = Client.flush_inbox(rec_acc)

            assert {:ok, update} =
                     Client.wait_for_inbox_update(rec_acc, dm_key,
                       attempts: 5,
                       match: fn update -> update["last_message_text"] == text end
                     )

            assert update["unread_count"] >= 1

            assert {:error, :timeout} =
                     Client.wait_for_inbox_updates(rec_acc, attempts: 1, timeout: 50)

            {:ok, _sender_after_close} = Client.close_conversation(sender, dm_key)
            {rec_acc, map_acc}
          end)
        end)

      assert map_size(dm_keys) == sender_count
    end
  end

  describe "multi-session consistency" do
    test "multiple sockets for same participant receive identical updates" do
      participant_id = "user:mirrored"
      other_id = "user:peer"

      {:ok, primary} = Client.start(participant_id)
      {:ok, primary, snapshot_primary} = Client.join_inbox(primary)
      assert snapshot_primary["conversations"] == []

      {:ok, secondary} = Client.start(participant_id)
      {:ok, secondary, snapshot_secondary} = Client.join_inbox(secondary)
      assert snapshot_secondary["conversations"] == []

      {:ok, primary, reply_primary} = Client.join_conversation(primary, other_id)
      dm_key = reply_primary["dm_key"]
      assert reply_primary["messages"] == []

      {:ok, secondary, reply_secondary} = Client.join_conversation(secondary, {:dm_key, dm_key})
      assert reply_secondary["dm_key"] == dm_key

      {:ok, peer} = Client.start(other_id)
      {:ok, peer, _} = Client.join_conversation(peer, {:dm_key, dm_key})

      {:ok, _event} = Client.send_message(peer, participant_id, "sync both tabs")

      assert {:ok, message_primary} =
               Client.wait_for_message(primary, dm_key,
                 attempts: 5,
                 match: fn payload -> payload["text"] == "sync both tabs" end
               )

      assert {:ok, message_secondary} =
               Client.wait_for_message(secondary, dm_key,
                 attempts: 5,
                 match: fn payload -> payload["text"] == "sync both tabs" end
               )

      assert message_primary == message_secondary

      :ok = Client.flush_inbox(primary)

      assert {:ok, updates_primary} = Client.wait_for_inbox_updates(primary, attempts: 5)
      assert {:ok, updates_secondary} = Client.wait_for_inbox_updates(secondary, attempts: 5)

      assert updates_primary == updates_secondary
      assert [%{"dm_key" => ^dm_key, "last_message_text" => "sync both tabs"}] = updates_primary

      assert {:error, :timeout} = Client.wait_for_inbox_updates(primary, attempts: 1, timeout: 50)

      assert {:error, :timeout} =
               Client.wait_for_inbox_updates(secondary, attempts: 1, timeout: 50)
    end
  end

  describe "offline backlog recovery" do
    test "participant receives stored history once when coming back online" do
      recipient_id = "user:offline"
      message_count = 10

      offline_messages =
        Enum.map(1..message_count, fn idx ->
          sender_id = "user:offline-sender#{idx}"
          dm_key = Fleetlm.Chat.generate_dm_key(sender_id, recipient_id)
          text = "offline backlog #{idx}"

          {:ok, _event} = Fleetlm.Chat.send_message(sender_id, recipient_id, text)
          {dm_key, sender_id, text}
        end)

      {:ok, recipient} = Client.start(recipient_id)
      {:ok, recipient, snapshot} = Client.join_inbox(recipient)

      conversations = snapshot["conversations"]
      assert length(conversations) == message_count

      Enum.each(offline_messages, fn {dm_key, sender_id, _text} ->
        assert Enum.any?(conversations, fn convo ->
                 convo["dm_key"] == dm_key and convo["last_sender_id"] in [nil, sender_id]
               end)
      end)

      recipient =
        Enum.reduce(offline_messages, recipient, fn {dm_key, _sender_id, text}, acc ->
          {:ok, acc, reply} = Client.join_conversation(acc, {:dm_key, dm_key})

          assert Enum.map(reply["messages"], & &1["text"]) == [text]

          assert {:error, :timeout} =
                   Client.wait_for_message(acc, dm_key, attempts: 1, timeout: 50)

          acc
        end)

      follow_ups =
        Enum.map(offline_messages, fn {dm_key, sender_id, _text} ->
          follow_up = "follow up #{sender_id}"
          {:ok, _event} = Fleetlm.Chat.send_message(sender_id, recipient_id, follow_up)
          {dm_key, sender_id, follow_up}
        end)

      :ok = Client.flush_inbox(recipient)

      assert {:ok, updates} = gather_inbox_updates(recipient, message_count)

      Enum.each(follow_ups, fn {dm_key, sender_id, follow_up} ->
        update = Enum.find(updates, &(&1["dm_key"] == dm_key))
        refute is_nil(update)
        assert update["last_sender_id"] == sender_id
        assert update["last_message_text"] == follow_up
      end)
    end
  end

  describe "broadcast interleaving" do
    test "broadcast fan-out stays distinct during dm bursts" do
      {:ok, alice} = Client.start("user:alice-burst")
      {:ok, alice, _} = Client.join_inbox(alice)

      {:ok, bob} = Client.start("user:bob-burst")
      {:ok, bob, _} = Client.join_inbox(bob)

      {:ok, carol} = Client.start("user:carol-broadcast")
      {:ok, carol, _} = Client.join_inbox(carol)

      {:ok, alice, reply_ab} = Client.join_conversation(alice, bob.participant_id)
      dm_key = reply_ab["dm_key"]
      {:ok, bob, _} = Client.join_conversation(bob, {:dm_key, dm_key})

      {:ok, alice, _} = Client.join_conversation(alice, :broadcast)
      {:ok, carol, _} = Client.join_conversation(carol, :broadcast)

      dm_messages = 1..5
      broadcast_messages = []

      broadcast_messages =
        Enum.reduce(dm_messages, broadcast_messages, fn idx, acc ->
          text = "dm burst #{idx}"
          {:ok, _event} = Client.send_message(alice, bob.participant_id, text)

          assert {:ok, _own_copy} =
                   Client.wait_for_message(alice, dm_key,
                     attempts: 5,
                     match: fn payload -> payload["text"] == text end
                   )

          assert {:ok, bob_copy} =
                   Client.wait_for_message(bob, dm_key,
                     attempts: 5,
                     match: fn payload -> payload["text"] == text end
                   )

          assert bob_copy["sender_id"] == alice.participant_id

          acc =
            if rem(idx, 2) == 0 do
              broadcast_text = "broadcast ping #{div(idx, 2)}"
              {:ok, _broadcast} = Client.send_broadcast(alice, broadcast_text)

              assert {:ok, _} =
                       Client.wait_for_message(alice, "broadcast",
                         attempts: 5,
                         match: fn payload -> payload["text"] == broadcast_text end
                       )

              assert {:ok, _} =
                       Client.wait_for_message(carol, "broadcast",
                         attempts: 5,
                         match: fn payload -> payload["text"] == broadcast_text end
                       )

              [broadcast_text | acc]
            else
              acc
            end

          assert {:error, :not_joined} =
                   Client.wait_for_message(carol, dm_key, attempts: 1, timeout: 50)

          acc
        end)

      :ok = Client.flush_inbox(bob)
      :ok = Client.flush_inbox(alice)

      assert {:ok, update_bob} =
               Client.wait_for_inbox_update(bob, dm_key,
                 attempts: 5,
                 match: fn update -> update["last_message_text"] == "dm burst 5" end
               )

      assert update_bob["unread_count"] == Enum.count(dm_messages)

      assert {:ok, update_alice} =
               Client.wait_for_inbox_update(alice, dm_key,
                 attempts: 5,
                 match: fn update -> update["last_message_text"] == "dm burst 5" end
               )

      assert update_alice["unread_count"] == 0

      assert {:error, :timeout} = Client.wait_for_inbox_updates(alice, attempts: 1, timeout: 50)
      assert {:error, :timeout} = Client.wait_for_inbox_updates(bob, attempts: 1, timeout: 50)

      Enum.each(Enum.reverse(broadcast_messages), fn broadcast_text ->
        assert {:error, :timeout} =
                 Client.wait_for_message(alice, "broadcast",
                   attempts: 1,
                   match: fn payload -> payload["text"] == broadcast_text end,
                   timeout: 50
                 )

        assert {:error, :timeout} =
                 Client.wait_for_message(carol, "broadcast",
                   attempts: 1,
                   match: fn payload -> payload["text"] == broadcast_text end,
                   timeout: 50
                 )
      end)
    end
  end

  describe "cache fallback" do
    test "clearing caches preserves conversation history" do
      alice_id = "user:cache-alice"
      bob_id = "user:cache-bob"

      {:ok, alice} = Client.start(alice_id)
      {:ok, alice, _} = Client.join_inbox(alice)

      {:ok, bob} = Client.start(bob_id)
      {:ok, bob, _} = Client.join_inbox(bob)

      {:ok, alice, reply_ab} = Client.join_conversation(alice, bob_id)
      dm_key = reply_ab["dm_key"]
      {:ok, bob, _} = Client.join_conversation(bob, {:dm_key, dm_key})

      {:ok, _first} = Client.send_message(alice, bob_id, "before reset")

      assert {:ok, _msg_bob} =
               Client.wait_for_message(bob, dm_key,
                 attempts: 5,
                 match: fn payload -> payload["text"] == "before reset" end
               )

      assert :ok = Fleetlm.Chat.Cache.reset()

      {:ok, _} = Client.close_conversation(bob, dm_key)
      {:ok, _} = Client.close_inbox(bob)

      {:ok, bob_reconnect} = Client.start(bob_id)
      {:ok, bob_reconnect, _} = Client.join_inbox(bob_reconnect)

      {:ok, bob_reconnect, join_reply_before} =
        Client.join_conversation(bob_reconnect, {:dm_key, dm_key})

      assert Enum.map(join_reply_before["messages"], & &1["text"]) == ["before reset"]

      {:ok, _second} = Client.send_message(bob_reconnect, alice_id, "after reset")

      assert {:ok, _msg_alice} =
               Client.wait_for_message(alice, dm_key,
                 attempts: 5,
                 match: fn payload -> payload["text"] == "after reset" end
               )

      :ok = Client.flush_inbox(alice)
      :ok = Client.flush_inbox(bob_reconnect)

      assert {:ok, update_alice} =
               Client.wait_for_inbox_update(alice, dm_key,
                 attempts: 5,
                 match: fn update -> update["last_message_text"] == "after reset" end
               )

      assert update_alice["unread_count"] == 1

      assert {:ok, update_bob} =
               Client.wait_for_inbox_update(bob_reconnect, dm_key,
                 attempts: 5,
                 match: fn update -> update["last_message_text"] == "after reset" end
               )

      assert update_bob["unread_count"] == 0

      assert {:error, :timeout} = Client.wait_for_inbox_updates(alice, attempts: 1, timeout: 50)

      assert {:error, :timeout} =
               Client.wait_for_inbox_updates(bob_reconnect, attempts: 1, timeout: 50)

      {:ok, alice} = Client.close_conversation(alice, dm_key)

      {:ok, _alice_after, join_reply_after} = Client.join_conversation(alice, {:dm_key, dm_key})

      assert Enum.map(join_reply_after["messages"], & &1["text"]) ==
               ["before reset", "after reset"]
    end
  end

  defp gather_inbox_updates(client, expected_count) when expected_count > 0 do
    tries = max(expected_count * 2, 30)
    do_gather_inbox_updates(client, expected_count, tries, %{}, MapSet.new())
  end

  defp do_gather_inbox_updates(_client, expected_count, _tries, acc, _seen)
       when map_size(acc) == expected_count do
    {:ok, Map.values(acc)}
  end

  defp do_gather_inbox_updates(_client, expected_count, 0, acc, _seen) do
    flunk("expected #{expected_count} unique inbox updates, received #{map_size(acc)}")
  end

  defp do_gather_inbox_updates(client, expected_count, tries, acc, seen) do
    case Client.wait_for_inbox_updates(client, attempts: 3, timeout: 800) do
      {:ok, updates} ->
        Enum.each(updates, fn update ->
          dm_key = update["dm_key"]

          if MapSet.member?(seen, dm_key) do
            flunk("received duplicate inbox delta for #{dm_key}")
          end
        end)

        acc =
          Enum.reduce(updates, acc, fn update, map ->
            Map.put(map, update["dm_key"], update)
          end)

        seen =
          Enum.reduce(updates, seen, fn update, set ->
            MapSet.put(set, update["dm_key"])
          end)

        if map_size(acc) >= expected_count do
          {:ok, Map.values(acc)}
        else
          do_gather_inbox_updates(client, expected_count, tries - 1, acc, seen)
        end

      {:error, :timeout} ->
        do_gather_inbox_updates(client, expected_count, tries - 1, acc, seen)
    end
  end
end
