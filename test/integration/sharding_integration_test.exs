defmodule Fleetlm.Integration.ShardingIntegrationTest do
  use Fleetlm.DataCase

  alias Fleetlm.Runtime.Gateway
  alias Fleetlm.Runtime.Sharding.{HashRing, SlotServer, Slots}
  alias Fleetlm.Conversation.{Participants, ChatMessage}
  alias Fleetlm.Conversation

  @sessions 6
  @messages_per_session 4

  setup do
    Application.put_env(:fleetlm, :persistence_worker_mode, :noop)

    on_exit(fn ->
      Application.put_env(:fleetlm, :persistence_worker_mode, :noop)
    end)

    original_ring = HashRing.current()

    on_exit(fn -> HashRing.put_current!(original_ring) end)

    {:ok, pairs: participant_pairs(), original_ring: original_ring}
  end

  test "parallel appends across sessions remain isolated", %{pairs: pairs} do
    sessions =
      pairs
      |> Enum.take(@sessions)
      |> Enum.map(fn {initiator, peer} ->
        {:ok, session} =
          Conversation.start_session(%{
            initiator_id: initiator,
            peer_id: peer
          })

        session
      end)

    expected =
      Map.new(sessions, fn session ->
        contents =
          Enum.map(1..@messages_per_session, fn seq -> "session-#{session.id}-#{seq}" end)

        {session.id, contents}
      end)

    for session <- sessions do
      tasks =
        for seq <- 1..@messages_per_session do
          Task.async(fn ->
            Gateway.append_message(session.id, %{
              sender_id: session.initiator_id,
              kind: "text",
              content: %{text: "session-#{session.id}-#{seq}"},
              idempotency_key: "#{session.id}-#{seq}"
            })
          end)
        end

      results = Enum.map(tasks, &Task.await(&1, 1_000))

      assert Enum.all?(results, &match?({:ok, %ChatMessage{}}, &1))
    end

    for session <- sessions do
      messages = Gateway.replay_messages(session.id, limit: 10)
      texts = Enum.map(messages, & &1.content["text"]) |> Enum.sort()
      expected_texts = expected |> Map.fetch!(session.id) |> Enum.sort()

      assert texts == expected_texts
      assert Enum.frequencies(texts) == Enum.frequencies(expected_texts)
    end

    all_ids =
      sessions
      |> Enum.flat_map(fn session ->
        Gateway.replay_messages(session.id, limit: 10)
        |> Enum.map(& &1.id)
      end)

    assert length(all_ids) == Enum.uniq(all_ids) |> length()
  end

  test "slots restart without losing message history", %{pairs: pairs} do
    {initiator, peer} = hd(Enum.drop(pairs, @sessions))

    {:ok, session} =
      Conversation.start_session(%{
        initiator_id: initiator,
        peer_id: peer
      })

    slot = HashRing.slot_for_session(session.id)

    Enum.each(1..3, fn idx ->
      assert {:ok, _msg} =
               Gateway.append_message(session.id, %{
                 sender_id: session.initiator_id,
                 kind: "text",
                 content: %{text: "before-#{idx}"},
                 idempotency_key: "before-#{idx}"
               })
    end)

    pid = slot_pid(slot)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, _, _, _}, 1_000

    :ok = ensure_slot(slot)

    replayed = Gateway.replay_messages(session.id, limit: 10)
    replay_texts = Enum.map(replayed, & &1.content["text"]) |> Enum.sort()
    assert replay_texts == Enum.sort(for idx <- 1..3, do: "before-#{idx}")

    assert {:ok, _msg} =
             Gateway.append_message(session.id, %{
               sender_id: session.initiator_id,
               kind: "text",
               content: %{text: "after"}
             })

    final_messages = Gateway.replay_messages(session.id, limit: 10)
    final_texts = Enum.map(final_messages, & &1.content["text"]) |> Enum.sort()
    assert final_texts == Enum.sort(["after" | Enum.map(1..3, &"before-#{&1}")])
  end

  test "rebalance handoff preserves durability", %{pairs: pairs, original_ring: original_ring} do
    {initiator, peer} = Enum.at(pairs, @sessions)

    {:ok, session} =
      Conversation.start_session(%{
        initiator_id: initiator,
        peer_id: peer
      })

    slot = HashRing.slot_for_session(session.id)

    Enum.each(1..2, fn idx ->
      assert {:ok, _} =
               Gateway.append_message(session.id, %{
                 sender_id: session.initiator_id,
                 kind: "text",
                 content: %{text: "steady-#{idx}"},
                 idempotency_key: "steady-#{idx}"
               })
    end)

    initial_db = message_texts(session.id)
    assert Enum.sort(initial_db) == Enum.sort(["steady-1", "steady-2"])

    original_pid = slot_pid(slot)

    draining_assignments = Map.put(original_ring.assignments, slot, :fake@node)

    draining_ring = %{
      original_ring
      | assignments: draining_assignments,
        nodes: Enum.uniq([Node.self(), :fake@node])
    }

    HashRing.put_current!(draining_ring)
    ref = Process.monitor(original_pid)
    GenServer.cast(original_pid, :rebalance)
    assert_receive {:DOWN, ^ref, _, _, _}, 1_000

    assert_raise ErlangError, fn ->
      Gateway.append_message(session.id, %{
        sender_id: session.initiator_id,
        kind: "text",
        content: %{text: "during-drain"},
        idempotency_key: "during-drain"
      })
    end

    HashRing.put_current!(original_ring)
    :ok = ensure_slot(slot)

    assert {:ok, _} =
             Gateway.append_message(session.id, %{
               sender_id: session.initiator_id,
               kind: "text",
               content: %{text: "post-rebalance"},
               idempotency_key: "post-rebalance"
             })

    texts = message_texts(session.id) |> Enum.sort()
    assert texts == Enum.sort(["steady-1", "steady-2", "post-rebalance"])
    refute Enum.member?(texts, "during-drain")
  end

  defp participant_pairs do
    1..(@sessions * 2 + 4)
    |> Enum.map(fn idx ->
      id = "user:integration:#{idx}"

      {:ok, _} =
        Participants.upsert_participant(%{
          id: id,
          kind: "user",
          display_name: "User #{idx}"
        })

      id
    end)
    |> Enum.chunk_every(2)
    |> Enum.map(fn [a, b] -> {a, b} end)
  end

  defp ensure_slot(slot) do
    # Wait for any lingering slot process to fully terminate
    case Registry.lookup(Fleetlm.Runtime.Sharding.LocalRegistry, {:shard, slot}) do
      [{pid, _}] when is_pid(pid) ->
        if Process.alive?(pid) do
          ref = Process.monitor(pid)
          Process.exit(pid, :kill)

          receive do
            {:DOWN, ^ref, :process, ^pid, _} -> :ok
          after
            1000 -> :ok
          end
        end

      [] ->
        :ok
    end

    case Slots.ensure_slot_started(slot) do
      :ok ->
        allow_sandbox_access(slot_pid(slot))
        :ok

      {:error, _} ->
        {:ok, pid} = SlotServer.start_link(slot)
        allow_sandbox_access(pid)
        :ok
    end
  rescue
    ArgumentError ->
      {:ok, pid} = SlotServer.start_link(slot)
      allow_sandbox_access(pid)
      :ok
  end

  defp slot_pid(slot, attempts \\ 20) do
    case Registry.lookup(Fleetlm.Runtime.Sharding.LocalRegistry, {:shard, slot}) do
      [{pid, _}] ->
        pid

      [] when attempts > 0 ->
        Process.sleep(25)
        slot_pid(slot, attempts - 1)

      [] ->
        flunk("slot #{slot} did not start")
    end
  end

  defp message_texts(session_id) do
    Conversation.list_messages(session_id, limit: 20)
    |> Enum.map(& &1.content["text"])
  end
end
