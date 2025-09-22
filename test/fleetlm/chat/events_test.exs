defmodule Fleetlm.Chat.EventsTest do
  use FleetlmWeb.ChannelCase

  alias Fleetlm.Chat

  describe "runtime PubSub fanout" do
    test "dm messages and inbox activity are broadcast" do
      user_a = "user:alice"
      user_b = "user:bob"
      dm_key = Chat.generate_dm_key(user_a, user_b)

      Phoenix.PubSub.subscribe(Fleetlm.PubSub, "dm:" <> dm_key)
      Phoenix.PubSub.subscribe(Fleetlm.PubSub, "participant:" <> user_a)
      Phoenix.PubSub.subscribe(Fleetlm.PubSub, "participant:" <> user_b)

      Chat.inbox_snapshot(user_a)
      Chat.inbox_snapshot(user_b)

      {:ok, event} = Chat.send_dm_message(user_a, user_b, "Hello Bob!")

      assert_receive {:dm_message, payload}
      assert payload["id"] == event.id
      assert payload["text"] == "Hello Bob!"
      assert payload["sender_id"] == user_a

      inbox_updates =
        for _ <- 1..2, into: %{} do
          assert_receive {:dm_activity, payload}, 500
          {payload["participant_id"], payload}
        end

      inbox_a = Map.fetch!(inbox_updates, user_a)
      inbox_b = Map.fetch!(inbox_updates, user_b)

      assert inbox_a["dm_key"] == dm_key
      assert inbox_a["other_participant_id"] == user_b
      assert inbox_a["last_message_text"] == "Hello Bob!"

      assert inbox_b["dm_key"] == dm_key
      assert inbox_b["other_participant_id"] == user_a
      assert inbox_b["last_message_text"] == "Hello Bob!"
    end

    test "broadcast messages are faned out" do
      user = "admin:system"
      Phoenix.PubSub.subscribe(Fleetlm.PubSub, "broadcast")

      {:ok, event} = Chat.send_broadcast_message(user, "Hello all")

      assert_receive {:broadcast_message, payload}
      assert payload["id"] == event.id
      assert payload["sender_id"] == user
      assert payload["text"] == "Hello all"
    end
  end
end
