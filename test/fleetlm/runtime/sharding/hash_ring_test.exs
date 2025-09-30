defmodule Fleetlm.Runtime.HashRingTest do
  use ExUnit.Case, async: false

  alias Fleetlm.Runtime.HashRing

  setup do
    HashRing.reset!()

    on_exit(fn ->
      HashRing.reset!()
    end)

    :ok
  end

  test "build/2 assigns each slot to a node" do
    ring = HashRing.build(16, [:"node1@127.0.0.1", :"node2@127.0.0.1"])

    assert ring.slot_count == 16
    assert Enum.sort(ring.nodes) == [:"node1@127.0.0.1", :"node2@127.0.0.1"]

    assert ring.assignments |> map_size() == 16

    assert ring.assignments |> Map.values() |> Enum.uniq() |> Enum.sort() ==
             [:"node1@127.0.0.1", :"node2@127.0.0.1"]
  end

  test "refresh!/0 persists ring in persistent_term" do
    ring = HashRing.refresh!()
    stored = HashRing.current()

    assert ring == stored
    assert ring.generation > 0
  end

  test "slot_for_session/1 is deterministic" do
    HashRing.put_current!(HashRing.build(128, [Node.self()]))

    slot = HashRing.slot_for_session("abc123")
    assert slot == HashRing.slot_for_session("abc123")
    refute slot == HashRing.slot_for_session("different")
  end

  test "owner_node/1 reflects persisted assignments" do
    ring = HashRing.build(8, [Node.self()])
    HashRing.put_current!(ring)

    assert Enum.all?(0..7, fn slot -> HashRing.owner_node(slot) == Node.self() end)
  end

  test "distribution remains stable when node list unchanged" do
    nodes = [:"a@127.0.0.1", :"b@127.0.0.1", :"c@127.0.0.1"]

    ring1 = HashRing.build(64, nodes)
    ring2 = HashRing.build(64, Enum.shuffle(nodes))

    assert ring1.assignments == ring2.assignments
  end

  test "slots redistribute when node list changes" do
    nodes1 = [:"a@127.0.0.1", :"b@127.0.0.1"]
    nodes2 = [:"a@127.0.0.1", :"b@127.0.0.1", :"c@127.0.0.1"]

    ring1 = HashRing.build(64, nodes1)
    ring2 = HashRing.build(64, nodes2)

    assert ring1.assignments != ring2.assignments
    assert MapSet.new(Map.values(ring2.assignments)) == MapSet.new(nodes2)
  end
end
