defmodule Fleetlm.Runtime.RouterTest do
  use Fleetlm.StorageCase, async: false

  alias Fleetlm.Runtime.Router

  setup do
    session = create_test_session("alice", "bob")
    %{session: session}
  end

  describe "append_message/5 (local routing)" do
    test "appends message via local SessionServer", %{session: session} do
      {:ok, message} =
        Router.append_message(
          session.id,
          "alice",
          "text",
          %{"text" => "hello via router"}
        )

      assert message.seq == 1
      assert message.sender_id == "alice"
      assert message.content["text"] == "hello via router"
    end

    test "starts SessionServer if not already running", %{session: session} do
      # Ensure no session server is running
      case Registry.lookup(Fleetlm.Runtime.SessionRegistry, session.id) do
        [{pid, _}] ->
          Process.exit(pid, :kill)
          Process.sleep(10)

        [] ->
          :ok
      end

      # Router should start it automatically
      {:ok, message} =
        Router.append_message(
          session.id,
          "alice",
          "text",
          %{"text" => "auto-start"}
        )

      assert message.seq == 1

      # Verify server is now running
      assert [{_pid, _}] = Registry.lookup(Fleetlm.Runtime.SessionRegistry, session.id)
    end

    test "returns error for nonexistent session" do
      assert {:error, _reason} = Router.append_message("nonexistent", "alice", "text", %{})
    end
  end

  describe "join/3 (local routing)" do
    setup %{session: session} do
      # Append some messages first
      Router.append_message(session.id, "alice", "text", %{"seq" => 1})
      Router.append_message(session.id, "bob", "text", %{"seq" => 2})
      Router.append_message(session.id, "alice", "text", %{"seq" => 3})
      :ok
    end

    test "joins session and retrieves messages", %{session: session} do
      {:ok, result} = Router.join(session.id, "alice", last_seq: 0, limit: 10)

      assert length(result.messages) == 3
      assert Enum.map(result.messages, & &1["seq"]) == [1, 2, 3]
    end

    test "respects last_seq parameter", %{session: session} do
      {:ok, result} = Router.join(session.id, "alice", last_seq: 1, limit: 10)

      assert length(result.messages) == 2
      assert Enum.map(result.messages, & &1["seq"]) == [2, 3]
    end

    test "enforces authorization", %{session: session} do
      assert {:error, :unauthorized} = Router.join(session.id, "charlie", last_seq: 0)
    end
  end

  describe "drain/1 (local routing)" do
    test "skipped - drain requires async flush which is complex in tests", %{session: _session} do
      # Drain functionality is tested in integration tests
      :ok
    end
  end
end
