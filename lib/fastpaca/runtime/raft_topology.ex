defmodule Fastpaca.Runtime.RaftTopology do
  @moduledoc """
  Coordinates Raft group membership using battle-tested patterns from RabbitMQ and Consul.

  ## Design Principles (Boring = Reliable)

  - **Erlang distribution** for cluster membership (not Presence/CRDT)
  - **Coordinator pattern**: lowest node ID manages all group topology
  - **Continuous reconciliation**: coordinator ensures groups match desired state
  - **No global "ready" state**: nodes join and serve traffic ASAP

  ## Bootstrap

  - Coordinator: detects groups don't exist, bootstraps them with initial replicas
  - Non-coordinators: start local groups, join existing clusters
  - No racing: groups either exist or they don't (via :ra.members check)

  ## Dynamic Membership

  - Coordinator runs rebalancing on {:nodeup, _} and {:nodedown, _}
  - Uses rendezvous hashing for deterministic replica placement
  - Adds members first, then removes (safe rebalancing)
  """

  use GenServer
  require Logger

  alias Fastpaca.Runtime.RaftManager

  @reconcile_interval_ms 10_000
  @rebalance_debounce_ms 2_000

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns true if this node has local Raft groups running."
  def ready? do
    case Process.whereis(__MODULE__) do
      nil -> false
      pid -> GenServer.call(pid, :ready?)
    end
  end

  @doc "Returns all nodes in cluster (strongly consistent via Erlang distribution)."
  def all_nodes do
    [Node.self() | Node.list()] |> Enum.uniq() |> Enum.sort()
  end

  @doc "Backwards compatibility shim for code expecting ready_nodes/0."
  def ready_nodes, do: all_nodes()

  # GenServer callbacks

  @impl true
  def init(_opts) do
    # Start Ra system
    case :ra.start() do
      :ok -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :logger.set_application_level(:ra, :error)

    # Monitor cluster changes via boring Erlang
    :ok = :net_kernel.monitor_nodes(true, node_type: :visible)

    Logger.info("RaftTopology: starting on #{Node.self()}")

    # Bootstrap immediately, then reconcile continuously
    send(self(), :bootstrap)
    schedule_reconcile()

    {:ok, %{rebalance_timer: nil}}
  end

  @impl true
  def handle_call(:ready?, _from, state) do
    # Simple health: do my local groups exist?
    my_groups = compute_my_groups()
    ready = length(my_groups) > 0 and Enum.count(my_groups, &group_running?/1) >= div(length(my_groups), 2)
    {:reply, ready, state}
  end

  @impl true
  def handle_info(:bootstrap, state) do
    cluster = all_nodes()

    # Wait for expected cluster if CLUSTER_NODES is set (avoids bootstrap races in tests)
    expected = parse_expected_cluster_size()

    if expected > 1 and length(cluster) < expected do
      Logger.debug("RaftTopology: waiting for cluster #{length(cluster)}/#{expected}")
      Process.send_after(self(), :bootstrap, 500)
      {:noreply, state}
    else
      if coordinator?(cluster) do
        Logger.info("RaftTopology: coordinator bootstrapping #{RaftManager.num_groups()} groups")
        bootstrap_all_groups_async(cluster)
      else
        Logger.info("RaftTopology: non-coordinator joining existing groups")
        join_my_groups_async(cluster)
      end

      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:reconcile, state) do
    cluster = all_nodes()

    if coordinator?(cluster) do
      # Coordinator continuously reconciles all groups
      Enum.each(0..(RaftManager.num_groups() - 1), &reconcile_group(&1, cluster))
    end

    schedule_reconcile()
    {:noreply, state}
  end

  @impl true
  def handle_info({:nodeup, node, _info}, state) do
    Logger.info("RaftTopology: node up #{inspect(node)}")
    {:noreply, schedule_rebalance(state)}
  end

  @impl true
  def handle_info({:nodedown, node, _info}, state) do
    Logger.warning("RaftTopology: node down #{inspect(node)}")
    {:noreply, schedule_rebalance(state)}
  end

  @impl true
  def handle_info(:rebalance, state) do
    cluster = all_nodes()

    if coordinator?(cluster) do
      Logger.info("RaftTopology: rebalancing #{length(cluster)} nodes")
      # Use reconcile (not just rebalance) to ensure missing groups are created
      Enum.each(0..(RaftManager.num_groups() - 1), &reconcile_group(&1, cluster))
    end

    {:noreply, %{state | rebalance_timer: nil}}
  end

  # Private functions

  defp schedule_reconcile do
    Process.send_after(self(), :reconcile, @reconcile_interval_ms)
  end

  defp schedule_rebalance(state) do
    if state.rebalance_timer do
      Process.cancel_timer(state.rebalance_timer)
    end

    timer = Process.send_after(self(), :rebalance, @rebalance_debounce_ms)
    %{state | rebalance_timer: timer}
  end

  defp coordinator?(cluster) do
    Node.self() == List.first(cluster)
  end

  defp bootstrap_all_groups_async(cluster) do
    # Bootstrap async to avoid blocking GenServer
    Task.start(fn ->
      Enum.each(0..(RaftManager.num_groups() - 1), fn group_id ->
        ensure_group_exists(group_id, cluster)
      end)
      Logger.info("RaftTopology: bootstrap complete")
    end)
  end

  defp join_my_groups_async(cluster) do
    # Join async to avoid blocking GenServer
    # Non-coordinators wait for groups to be bootstrapped by coordinator
    my_groups = compute_my_groups(cluster)

    Task.start(fn ->
      Enum.each(my_groups, fn group_id ->
        wait_and_join_group(group_id)
      end)
      Logger.info("RaftTopology: joined #{length(my_groups)} groups")
    end)
  end

  defp wait_and_join_group(group_id) do
    server_id = RaftManager.server_id(group_id)

    # Poll until group exists somewhere in cluster (coordinator bootstrapping)
    case wait_for_group_exists(server_id, max_attempts: 60) do
      :ok ->
        # Group exists, start locally if not running
        unless group_running?(group_id) do
          RaftManager.start_group(group_id)
        end

      :timeout ->
        Logger.warning("RaftTopology: timeout waiting for group #{group_id} to be bootstrapped")
    end
  end

  defp wait_for_group_exists(server_id, max_attempts: max) do
    wait_for_group_exists(server_id, 0, max)
  end

  defp wait_for_group_exists(_server_id, attempt, max) when attempt >= max do
    :timeout
  end

  defp wait_for_group_exists(server_id, attempt, max) do
    case :ra.members({server_id, Node.self()}) do
      {:ok, _members, _leader} ->
        :ok

      _ ->
        Process.sleep(500)
        wait_for_group_exists(server_id, attempt + 1, max)
    end
  end

  defp ensure_group_exists(group_id, cluster) do
    server_id = RaftManager.server_id(group_id)

    case :ra.members({server_id, Node.self()}) do
      {:ok, _members, _leader} ->
        # Group exists
        :ok

      {:error, :noproc} ->
        # Group doesn't exist, bootstrap it
        bootstrap_group(group_id, cluster)

      {:timeout, _} ->
        # Might exist, start locally if we're a replica
        if Node.self() in replicas_for_group(group_id, cluster) do
          RaftManager.start_group(group_id)
        end

        :ok
    end
  end

  defp bootstrap_group(group_id, cluster) do
    replica_nodes = replicas_for_group(group_id, cluster)
    server_id = RaftManager.server_id(group_id)
    cluster_name = RaftManager.cluster_name(group_id)
    machine = {:module, Fastpaca.Runtime.RaftFSM, %{group_id: group_id}}

    server_ids = for node <- replica_nodes, do: {server_id, node}

    # Use global lock to ensure only one node across cluster bootstraps each group
    :global.trans({:raft_bootstrap, group_id}, fn ->
      case :ra.start_cluster(:default, cluster_name, machine, server_ids) do
        {:ok, _started, _not_started} ->
          :ok

        {:error, {:already_started, _}} ->
          :ok

        {:error, reason} ->
          Logger.warning("RaftTopology: failed to bootstrap group #{group_id}: #{inspect(reason)}")
          {:error, reason}
      end
    end, [Node.self() | Node.list()], 10_000)
  end

  defp reconcile_group(group_id, cluster) do
    ensure_group_exists(group_id, cluster)

    # After ensuring exists, reconcile membership
    rebalance_group(group_id, cluster)
  end

  defp rebalance_group(group_id, cluster) do
    server_id = RaftManager.server_id(group_id)
    my_server = {server_id, Node.self()}

    desired_members =
      cluster
      |> replicas_for_group(group_id)
      |> Enum.map(&{server_id, &1})

    case :ra.members(my_server) do
      {:ok, current, leader} ->
        to_add = desired_members -- current
        to_remove = current -- desired_members

        unless Enum.empty?(to_add) and Enum.empty?(to_remove) do
          Logger.info(
            "RaftTopology: rebalancing group #{group_id}: +#{length(to_add)} -#{length(to_remove)}"
          )
        end

        # Use leader for membership changes
        leader_ref = leader || my_server

        # Add first
        Enum.each(to_add, fn member ->
          add_member(group_id, leader_ref, member)
        end)

        # Then remove
        Enum.each(to_remove, fn member ->
          remove_member(group_id, leader_ref, member)
        end)

      {:error, :noproc} ->
        :ok

      {:timeout, _} ->
        :ok
    end
  end

  defp add_member(group_id, leader_ref, {_server_id, node} = member) do
    # Ensure group started on target
    :rpc.call(node, RaftManager, :start_group, [group_id])

    case :ra.add_member(leader_ref, member) do
      {:ok, _members, _leader} ->
        Logger.debug("RaftTopology: added #{inspect(node)} to group #{group_id}")
        :ok

      {:error, {:already_member, _}} ->
        :ok

      {:error, :not_leader} ->
        :ok

      {:error, reason} ->
        Logger.debug("RaftTopology: add failed for group #{group_id}: #{inspect(reason)}")
        {:error, reason}

      {:timeout, _} ->
        {:error, :timeout}
    end
  end

  defp remove_member(group_id, leader_ref, {server_id, node} = member) do
    case :ra.remove_member(leader_ref, member) do
      {:ok, _members, _leader} ->
        Logger.debug("RaftTopology: removed #{inspect(node)} from group #{group_id}")
        :rpc.call(node, :ra, :stop_server, [:default, {server_id, node}])
        :ok

      {:error, {:not_member, _}} ->
        :ok

      {:error, :not_leader} ->
        :ok

      {:error, reason} ->
        Logger.debug("RaftTopology: remove failed for group #{group_id}: #{inspect(reason)}")
        {:error, reason}

      {:timeout, _} ->
        {:error, :timeout}
    end
  end

  defp compute_my_groups(cluster \\ nil) do
    nodes = cluster || all_nodes()

    for group_id <- 0..(RaftManager.num_groups() - 1),
        Node.self() in replicas_for_group(group_id, nodes),
        do: group_id
  end

  defp replicas_for_group(group_id, cluster) do
    cluster
    |> Enum.map(fn node ->
      hash = :erlang.phash2({group_id, node})
      {hash, node}
    end)
    |> Enum.sort()
    |> Enum.take(3)
    |> Enum.map(fn {_hash, node} -> node end)
  end

  defp group_running?(group_id) do
    Process.whereis(RaftManager.server_id(group_id)) != nil
  end

  defp parse_expected_cluster_size do
    case System.get_env("CLUSTER_NODES") do
      nil -> 1
      "" -> 1
      nodes_str ->
        nodes_str
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> length()
    end
  end

  # Backwards compatibility stubs for DrainCoordinator

  defmodule Presence do
    def update(_pid, _topic, _key, _meta), do: :ok
    def list(_topic), do: []
  end

  def presence_topic, do: "raft:topology"
end
