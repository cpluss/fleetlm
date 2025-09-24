defmodule Fleetlm.Chat.ConversationSupervisorTest do
  use Fleetlm.DataCase

  alias Fleetlm.Chat.{ConversationSupervisor, DmKey}

  describe "ensure_started/1" do
    test "returns the same server regardless of participant ordering" do
      alice = "user:alice"
      bob = "user:bob"

      unordered_key = "#{bob}:#{alice}"
      dm = DmKey.parse!(unordered_key)

      assert {:ok, pid1} = ConversationSupervisor.ensure_started(unordered_key)
      assert {:ok, pid2} = ConversationSupervisor.ensure_started(dm)

      assert pid1 == pid2
    end
  end
end
