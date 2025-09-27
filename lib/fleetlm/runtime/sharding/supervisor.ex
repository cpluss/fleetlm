defmodule Fleetlm.Runtime.Sharding.Supervisor do
  @moduledoc """
  Distributed dynamic supervisor responsible for running shard-slot owner processes.

  The supervisor itself is replicated by Horde; it ensures that for every slot
  in the hash ring there is an owning process on the node selected by the
  distribution strategy. When cluster membership changes Horde moves only the
  affected slot processes, keeping other slots hot on their original nodes.
  """

  use Horde.DynamicSupervisor

  alias Fleetlm.Runtime.Sharding.DistributionStrategy

  def start_link(opts \\ []) do
    Horde.DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    defaults = [
      strategy: :one_for_one,
      members: local_members(__MODULE__, [Node.self()]),
      process_redistribution: :active,
      distribution_strategy: DistributionStrategy
    ]

    defaults
    |> Keyword.merge(opts)
    |> Horde.DynamicSupervisor.init()
  end

  defp local_members(name, nodes) do
    Enum.map(nodes, fn node -> {name, node} end)
  end
end
