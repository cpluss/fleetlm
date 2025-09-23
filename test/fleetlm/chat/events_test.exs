defmodule Fleetlm.Chat.EventsTest do
  use FleetlmWeb.ChannelCase

  alias Fleetlm.Chat
  alias Fleetlm.Chat.{Cache, InboxServer, InboxSupervisor}

  describe "runtime PubSub fanout" do
    test "dm messages and inbox activity are broadcast" do
      user_a = "user:alice"
      user_b = "user:bob"
      dm_key = Chat.generate_dm_key(user_a, user_b)

      Cache.reset()
      {:ok, _} = InboxSupervisor.ensure_started(user_a)
      {:ok, _} = InboxSupervisor.ensure_started(user_b)
      Phoenix.PubSub.subscribe(Fleetlm.PubSub, "conversation:" <> dm_key)
      Phoenix.PubSub.subscribe(Fleetlm.PubSub, "inbox:" <> user_a)
      Phoenix.PubSub.subscribe(Fleetlm.PubSub, "inbox:" <> user_b)

      Chat.inbox_snapshot(user_a)
      Chat.inbox_snapshot(user_b)

      {:ok, event} = Chat.send_message(user_a, user_b, "Hello Bob!")
      :ok = InboxServer.flush(user_a)
      :ok = InboxServer.flush(user_b)

      assert_receive {:dm_message, payload}
      assert payload["id"] == event.id
      assert payload["text"] == "Hello Bob!"
      assert payload["sender_id"] == user_a

      for participant <- [user_a, user_b] do
        assert_receive {:inbox_delta, %{updates: updates}}, 500
        payload = Enum.find(updates, &(&1["dm_key"] == dm_key))
        assert payload
        assert payload["participant_id"] == participant
        assert payload["other_participant_id"] in [user_a, user_b]
        assert payload["last_sender_id"] == user_a
        assert payload["last_message_text"] == "Hello Bob!"
        refute Map.has_key?(payload, "text")
        refute Map.has_key?(payload, "metadata")
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
