defmodule Fleetlm.Runtime.Sharding.Manager do
  @moduledoc """
  Control loop that keeps the consistent hash ring and slot owners aligned with
  the current cluster membership.

  In practical terms this process turns node joins/leaves into ring rebuilds and
  orchestrated slot migrations. It is the piece that makes the sharding layer
  behave like a distributed load balancer: we keep the ring updated, make sure
  every slot has a live owner (`SlotServer`), and ask those owners to drain and
  restart on the appropriate node when the ring changes.
  """

  use GenServer

  alias Fleetlm.Runtime.Sharding.{HashRing, Slots}
  alias Fleetlm.Runtime.Sharding.Supervisor, as: ShardSupervisor

  require Logger

  @type state :: %{generation: non_neg_integer()}

  def start_link(arg \\ []) do
    GenServer.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    :net_kernel.monitor_nodes(true, node_type: :visible)

    ring = HashRing.refresh!()
    sync_members(ring)

    Logger.info(
      "Shard manager initialised with #{ring.slot_count} slots on nodes=#{inspect(ring.nodes)}"
    )

    schedule_health_check()

    {:ok, %{generation: ring.generation}}
  end

  @impl true
  def handle_info({:nodeup, node, _info}, state) do
    Logger.info("Node #{inspect(node)} joined cluster; refreshing hash ring")
    {:noreply, rebuild_ring(state)}
  end

  def handle_info({:nodedown, node, _info}, state) do
    Logger.warning("Node #{inspect(node)} left cluster; refreshing hash ring")
    {:noreply, rebuild_ring(state)}
  end

  def handle_info(:health_check, state) do
    schedule_health_check()
    {:noreply, rebuild_ring(state)}
  end

  defp rebuild_ring(state) do
    ring = HashRing.refresh!()
    sync_members(ring)
    Slots.rebalance_all()

    %{state | generation: ring.generation}
  end

  defp schedule_health_check do
    Process.send_after(self(), :health_check, :timer.seconds(30))
  end

  defp sync_members(%{nodes: nodes}) do
    members = Enum.map(nodes, fn node -> {ShardSupervisor, node} end)

    :ok = Horde.Cluster.set_members(ShardSupervisor, members)
  end
end
