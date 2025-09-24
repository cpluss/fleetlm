defmodule FleetlmWeb.ChatChannelBehaviourTest do
  use FleetlmWeb.ChannelCase

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
