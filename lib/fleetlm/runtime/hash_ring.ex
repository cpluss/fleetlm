defmodule Fleetlm.Runtime.HashRing do
  @moduledoc """
  Consistent hash ring used to map session ids to shard slots and slots to owner nodes.

  The ring is materialised in `:persistent_term` so every node in the cluster can
  perform routing decisions without cross-node RPCs. Ring construction is purely
  deterministic: given the same sorted node list and slot count, every node will
  derive the exact same ownership table.
  """

  import Bitwise

  @type slot :: non_neg_integer()
  @type node_name :: node()

  @persist_key {:fleetlm, __MODULE__}
  @hash_space 1 |> bsl(32)

  defstruct [:slot_count, :assignments, :nodes, :generation]

  @type t :: %__MODULE__{
          slot_count: pos_integer(),
          assignments: %{slot() => node_name()},
          nodes: [node_name()],
          generation: non_neg_integer()
        }

  @doc """
  Compute the ring for the given nodes and slot count. This function is
  deterministic — the caller is responsible for persisting the struct via
  `persist/1` or `put_current!/1`.
  """
  @spec build(pos_integer(), [node_name()]) :: t()
  def build(slot_count, nodes) when slot_count > 0 do
    nodes =
      nodes
      |> Enum.uniq()
      |> Enum.sort()

    virtual_node_count = virtual_node_count()

    vnodes =
      for node <- nodes,
          replica <- 0..(virtual_node_count - 1) do
        point = hash({node, replica})
        {point, node}
      end
      |> Enum.sort_by(&elem(&1, 0))

    assignments =
      for slot <- 0..(slot_count - 1), into: %{} do
        slot_hash = hash({:slot, slot})
        {slot, owner_for(slot_hash, vnodes, nodes)}
      end

    %__MODULE__{
      slot_count: slot_count,
      assignments: assignments,
      nodes: nodes,
      generation: generation() + 1
    }
  end

  defp owner_for(_hash, _vnodes, []), do: Node.self()

  defp owner_for(hash, vnodes, nodes) do
    case Enum.find(vnodes, fn {point, _} -> point >= hash end) do
      {_, node} ->
        node

      nil ->
        case vnodes do
          [] -> hd(nodes)
          [{_, node} | _] -> node
        end
    end
  end

  @doc """
  Rebuild the ring based on the current cluster node list and persist it.
  Returns the stored ring.
  """
  @spec refresh!() :: t()
  def refresh! do
    nodes = current_nodes()
    slot_count = slot_count()
    ring = build(slot_count, nodes)
    put_current!(ring)
  end

  @doc """
  Return the persisted ring. If no ring has been stored yet, build one using the
  local node list and persist it.
  """
  @spec current() :: t()
  def current do
    case :persistent_term.get(@persist_key, :undefined) do
      :undefined -> refresh!()
      ring -> ring
    end
  end

  @doc """
  Persist the given ring for immediate use.
  """
  @spec put_current!(t()) :: t()
  def put_current!(%__MODULE__{} = ring) do
    :persistent_term.put(@persist_key, ring)
    ring
  end

  @doc """
  Forget the stored ring. Intended for tests.
  """
  @spec reset!() :: :ok
  def reset! do
    :persistent_term.erase(@persist_key)
    :ok
  end

  @doc """
  Determine the slot for the given session id using the configured slot count.
  """
  @spec slot_for_session(String.t()) :: slot()
  def slot_for_session(session_id) when is_binary(session_id) do
    %{slot_count: slot_count} = current()
    :erlang.phash2(session_id, slot_count)
  end

  @doc """
  Fetch the owning node for the given slot.
  """
  @spec owner_node(slot()) :: node_name()
  def owner_node(slot) when is_integer(slot) and slot >= 0 do
    %{assignments: assignments} = current()
    Map.fetch!(assignments, slot)
  end

  @doc """
  Return debugging info for introspection endpoints.
  """
  @spec info() :: map()
  def info do
    %{slot_count: slot_count, assignments: assignments, nodes: nodes, generation: generation} =
      current()

    %{
      slot_count: slot_count,
      nodes: nodes,
      generation: generation,
      # sample distribution statistics to help ops understand balance
      slots_per_node: assignments |> Map.values() |> Enum.frequencies()
    }
  end

  defp slot_count do
    Application.get_env(:fleetlm, __MODULE__, [])
    |> Keyword.get(:slot_count, 512)
  end

  defp virtual_node_count do
    Application.get_env(:fleetlm, __MODULE__, [])
    |> Keyword.get(:virtual_nodes_per_node, 128)
    |> max(1)
  end

  defp current_nodes do
    [Node.self() | Node.list()]
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp generation do
    case :persistent_term.get(@persist_key, :undefined) do
      :undefined -> 0
      %__MODULE__{generation: generation} -> generation
    end
  end

  defp hash(term) do
    :erlang.phash2(term, @hash_space)
  end
end
