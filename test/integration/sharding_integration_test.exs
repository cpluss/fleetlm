defmodule Fleetlm.Integration.ShardingIntegrationTest do
  use Fleetlm.DataCase

  alias Fleetlm.Runtime.Gateway
  alias Fleetlm.Runtime.Sharding.HashRing
  alias Fleetlm.Conversation.{Participants, ChatMessage}
  alias Fleetlm.Conversation

  @sessions 6
  @messages_per_session 4

  setup do
    Application.put_env(:fleetlm, :persistence_worker_mode, :noop)

    on_exit(fn ->
      Application.put_env(:fleetlm, :persistence_worker_mode, :noop)
    end)

    {:ok, pairs: participant_pairs()}
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
    :ok = Fleetlm.Runtime.Sharding.Slots.ensure_slot_started(slot)
    allow_sandbox_access(slot_pid(slot))
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
end
