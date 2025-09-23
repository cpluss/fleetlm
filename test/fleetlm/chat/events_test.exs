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

      for participant <- [user_a, user_b] do
        assert_receive {:dm_activity, payload}, 500
        assert payload["participant_id"] == participant
        assert payload["dm_key"] == dm_key
        assert payload["other_participant_id"] in [user_a, user_b]
        assert payload["last_sender_id"] == user_a
        assert payload["last_message_text"] in [nil, ""]
      end
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
