defmodule Fleetlm.Runtime.Sharding.SlotServerTest do
  use Fleetlm.DataCase

  import Fleetlm.TestSupport.Sharding
  import ExUnit.CaptureLog

  alias Fleetlm.Runtime.Gateway
  alias Fleetlm.Runtime.Sharding.HashRing
  alias Fleetlm.Runtime.Storage.DiskLog
  alias Fleetlm.Conversation.Participants
  alias Fleetlm.Conversation

  setup do
    Application.put_env(:fleetlm, :persistence_worker_mode, :noop)

    {:ok, initiator} =
      Participants.upsert_participant(%{
        id: "user:slot:init",
        kind: "user",
        display_name: "Init"
      })

    {:ok, peer} =
      Participants.upsert_participant(%{
        id: "user:slot:peer",
        kind: "user",
        display_name: "Peer"
      })

    {:ok, session} =
      Conversation.start_session(%{
        initiator_id: initiator.id,
        peer_id: peer.id
      })

    slot = HashRing.slot_for_session(session.id)
    _pid = ensure_slot!(slot)

    on_exit(fn -> Application.put_env(:fleetlm, :persistence_worker_mode, :noop) end)

    {:ok, session: session, slot: slot}
  end

  describe "slot restarts" do
    test "router recovers after slot crash", %{session: session, slot: slot} do
      pid = slot_pid!(slot)
      ref = Process.monitor(pid)

      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, _, _, _}, 1_000

      _ = ensure_slot!(slot)

      _new_pid = slot_pid!(slot)

      assert {:ok, _message} =
               Gateway.append_message(session.id, %{
                 sender_id: session.initiator_id,
                 kind: "text",
                 content: %{text: "post-restart"}
               })
    end
  end

  describe "disk log failures" do
    test "append surfaces disk log sync errors", %{session: session, slot: slot} do
      capture_log(fn ->
        pid = slot_pid!(slot)

        :sys.replace_state(pid, fn state ->
          DiskLog.close(state.disk_log)
          %{state | disk_log: :invalid_handle}
        end)

        assert {:error, {:disk_log_failed, _}} =
                 Gateway.append_message(session.id, %{
                   sender_id: session.initiator_id,
                   kind: "text",
                   content: %{text: "should-fail"},
                   idempotency_key: "disk-failure"
                 })

        persisted = Conversation.list_messages(session.id, limit: 5)
        texts = Enum.map(persisted, & &1.content["text"])
        assert Enum.count(texts, &(&1 == "should-fail")) == 1

        restart_slot!(slot)
      end)
    end
  end
end
