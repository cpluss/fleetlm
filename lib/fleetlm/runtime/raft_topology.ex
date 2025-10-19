defmodule Fleetlm.Runtime.RaftTopology do
  @moduledoc """
  Coordinates Raft membership across the cluster.

  ## Responsibilities

  * Track cluster node membership via libcluster (`:net_kernel` monitor events)
  * Compute desired replicas per group using rendezvous hashing
  * Add/remove Raft replicas using Ra's membership APIs
  * Gate traffic to nodes that have actually joined their assigned groups
  * Replicate the ready-node set across the cluster using Phoenix Presence
  """

  use GenServer
  require Logger

  alias Fleetlm.Runtime.RaftManager

  @presence_topic "fleetlm:raft_ready_nodes"
  @rebalance_debounce_ms 5_000
  @readiness_interval_ms 1_000

  defmodule Presence do
    @moduledoc false
    use Phoenix.Presence,
      otp_app: :fleetlm,
      pubsub_server: Fleetlm.PubSub
  end

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns nodes that are READY to accept traffic (for routing).
  Filters out :joining nodes.
  """
  def ready_nodes do
    Presence.list(@presence_topic)
    |> Enum.map(fn {_key, %{metas: metas}} -> metas end)
    |> List.flatten()
    |> Enum.filter(&(&1[:status] == :ready))
    |> Enum.map(&(&1[:node]))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Returns ALL nodes in cluster (joining + ready) for placement decisions.
  This is the single source of truth for replicas_for_group/1.
  """
  def all_nodes do
    Presence.list(@presence_topic)
    |> Enum.map(fn {_key, %{metas: metas}} -> metas end)
    |> List.flatten()
    |> Enum.map(&(&1[:node]))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "Returns true if this node has joined all assigned Raft groups."
  def ready? do
    Node.self() in ready_nodes()
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    # Ensure Ra system is started
    case :ra.start() do
      :ok -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok = Phoenix.PubSub.subscribe(Fleetlm.PubSub, @presence_topic)
    :ok = :net_kernel.monitor_nodes(true, node_type: :visible)

    # CRITICAL: Track immediately as :joining so placement can see us!
    node_key = Atom.to_string(Node.self())
    meta = %{node: Node.self(), status: :joining, started_at: System.system_time(:millisecond)}

    case Presence.track(self(), @presence_topic, node_key, meta) do
      {:ok, _} -> :ok
      {:error, {:already_tracked, _}} -> :ok
    end

    Logger.info("RaftTopology: starting in joining state on #{Node.self()}")

    Process.send_after(self(), :check_readiness, @readiness_interval_ms)

    {:ok,
     %{
       status: :joining,
       rebalance_timer: nil
     }}
  end

  @impl true
  def handle_call(:ready?, _from, state) do
    {:reply, state.status == :ready, state}
  end

  @impl true
  def handle_call(:ready_nodes, _from, state) do
    {:reply, ready_nodes(), state}
  end

  @impl true
  def handle_info(:check_readiness, %{status: :ready} = state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:check_readiness, state) do
    # Wait for cluster to form before starting groups (avoid single-node clusters!)
    expected_nodes = parse_expected_cluster_size()
    current_cluster = [Node.self() | Node.list()] |> length()

    if current_cluster < expected_nodes do
      Logger.debug("RaftTopology: waiting for cluster (#{current_cluster}/#{expected_nodes} nodes connected)")
      Process.send_after(self(), :check_readiness, @readiness_interval_ms)
      {:noreply, state}
    else
      my_groups = compute_my_groups()

      # Start groups async via Task.Supervisor (Horde pattern - non-blocking!)
      not_started = Enum.reject(my_groups, &group_running?/1)

      unless Enum.empty?(not_started) do
        Logger.info("RaftTopology: Starting #{length(not_started)} groups asynchronously...")

        Task.Supervisor.async_stream_nolink(
          Fleetlm.RaftTaskSupervisor,
          not_started,
          fn group_id -> RaftManager.start_group(group_id) end,
          max_concurrency: 50,
          timeout: 30_000
        )
        |> Stream.run()
      end

      if Enum.all?(my_groups, &joined_group?/1) do
        Logger.info("RaftTopology: joined #{length(my_groups)} groups; marking ready")
        mark_ready()
        schedule_rebalance(state, immediate: true)
        {:noreply, %{state | status: :ready}}
      else
        Logger.debug("RaftTopology: joined #{Enum.count(my_groups, &joined_group?/1)}/#{length(my_groups)} groups")
        Process.send_after(self(), :check_readiness, @readiness_interval_ms)
        {:noreply, %{state | status: :joining}}
      end
    end
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
  def handle_info({:presence_diff, _topic, diff}, state) do
    log_presence_diff(diff)
    {:noreply, schedule_rebalance(state)}
  end

  @impl true
  def handle_info({:presence_diff, diff}, state) do
    log_presence_diff(diff)
    {:noreply, schedule_rebalance(state)}
  end

  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff", payload: diff}, state) do
    log_presence_diff(diff)
    {:noreply, schedule_rebalance(state)}
  end

  @impl true
  def handle_info(:rebalance, state) do
    ready = ready_nodes()

    cond do
      ready == [] ->
        Logger.debug("RaftTopology: skipping rebalance (no ready nodes yet)")

      coordinator?(ready) ->
        Logger.info("RaftTopology: coordinating rebalance across #{length(ready)} ready nodes")
        Enum.each(0..255, &rebalance_group(&1, ready))
        Logger.info("RaftTopology: rebalance complete")

      true ->
        Logger.debug("RaftTopology: skipping rebalance (coordinator is someone else)")
    end

    {:noreply, %{state | rebalance_timer: nil}}
  end

  @impl true
  def terminate(_reason, _state) do
    node_key = Atom.to_string(Node.self())
    _ = Presence.untrack(self(), @presence_topic, node_key)
    :ok
  end

  # Internal helpers

  defp compute_my_groups do
    # Use all_nodes() for placement (joining + ready), not just ready!
    candidates =
      case all_nodes() do
        [] -> fallback_nodes()
        nodes -> nodes
      end

    for group_id <- 0..255,
        Node.self() in rendezvous_select(candidates, group_id),
        do: group_id
  end

  defp group_running?(group_id) do
    Process.whereis(RaftManager.server_id(group_id)) != nil
  end

  defp joined_group?(group_id) do
    server_id = RaftManager.server_id(group_id)
    my_server = {server_id, Node.self()}

    case Process.whereis(server_id) do
      nil -> false
      _pid ->
        case :ra.members(my_server) do
          {:ok, members, _leader} -> my_server in members
          {:error, _} -> false
          {:timeout, _} -> false
        end
    end
  end

  defp mark_ready do
    node_key = Atom.to_string(Node.self())
    meta = %{node: Node.self(), status: :ready, ready_at: System.system_time(:millisecond)}

    # Update existing presence entry (already tracked as :joining in init/1)
    Presence.update(self(), @presence_topic, node_key, meta)
  end

  defp rebalance_group(group_id, _ready_nodes_for_coordinator_check) do
    cluster_name = cluster_name(group_id)
    server_id = RaftManager.server_id(group_id)

    ref =
      case Process.whereis(server_id) do
        nil -> cluster_name
        _pid -> {server_id, Node.self()}
      end

    # CRITICAL: Use all_nodes() for placement (joining + ready), not just ready!
    desired =
      all_nodes()
      |> rendezvous_select(group_id)
      |> Enum.map(&{server_id, &1})

    case :ra.members(ref) do
      {:ok, current, _leader} ->
        to_add = desired -- current
        to_remove = current -- desired

        unless Enum.empty?(to_add) and Enum.empty?(to_remove) do
          Logger.warning("Rebalancing group #{group_id}: +#{length(to_add)} -#{length(to_remove)}")
        end

        Enum.each(to_add, fn member -> add_member(group_id, member) end)

        unless Enum.empty?(to_add), do: Process.sleep(500)

        Enum.each(to_remove, fn member -> remove_member(group_id, member) end)

      {:error, :noproc} ->
        :ok

      {:error, reason} ->
        Logger.debug("RaftTopology: cannot fetch members for group #{group_id}: #{inspect(reason)}")

      {:timeout, _} ->
        Logger.debug("RaftTopology: timeout fetching members for group #{group_id}")
    end

    :ok
  end

  defp add_member(group_id, {_server_id, node} = member) do
    Logger.info("RaftTopology: adding #{inspect(node)} to group #{group_id}")

    # Ensure the group is started on the target node first
    :rpc.call(node, RaftManager, :start_group, [group_id])

    # Use server reference (not cluster name atom)
    case :ra.add_member(cluster_name(group_id), member) do
      {:ok, _members, _leader} ->
        Logger.info("RaftTopology: added #{inspect(node)} to group #{group_id}")
        :ok

      {:error, :not_leader} ->
        Logger.debug("RaftTopology: add_member not_leader for group #{group_id}")
        :ok

      {:error, reason} ->
        Logger.warning("RaftTopology: failed to add #{inspect(node)} to group #{group_id}: #{inspect(reason)}")
        {:error, reason}

      {:timeout, _} ->
        Logger.warning("RaftTopology: timeout adding #{inspect(node)} to group #{group_id}")
        {:error, :timeout}
    end
  end

  defp remove_member(group_id, {server_id, node} = member) do
    Logger.info("RaftTopology: removing #{inspect(node)} from group #{group_id}")

    # Use server reference (not cluster name atom)
    case :ra.remove_member(cluster_name(group_id), member) do
      {:ok, _members, _leader} ->
        Logger.info("RaftTopology: removed #{inspect(node)} from group #{group_id}")
        :rpc.call(node, :ra, :stop_server, [:default, {server_id, node}])
        :ok

      {:error, :not_leader} ->
        Logger.debug("RaftTopology: remove_member not_leader for group #{group_id}")
        :ok

      {:error, reason} ->
        Logger.warning("RaftTopology: failed to remove #{inspect(node)} from group #{group_id}: #{inspect(reason)}")
        {:error, reason}

      {:timeout, _} ->
        Logger.warning("RaftTopology: timeout removing #{inspect(node)} from group #{group_id}")
        {:error, :timeout}
    end
  end

  defp rendezvous_select(nodes, group_id) do
    nodes
    |> Enum.map(fn node ->
      score = :erlang.phash2({group_id, node})
      {score, node}
    end)
    |> Enum.sort()
    |> Enum.take(3)
    |> Enum.map(fn {_score, node} -> node end)
  end

  defp coordinator?(ready_nodes) do
    case ready_nodes do
      [] -> true
      nodes -> hd(nodes) == Node.self()
    end
  end

  defp schedule_rebalance(state, opts \\ [])

  defp schedule_rebalance(%{rebalance_timer: ref} = state, _opts) when is_reference(ref) or ref == :sent do
    state
  end

  defp schedule_rebalance(state, immediate: true) do
    send(self(), :rebalance)
    %{state | rebalance_timer: :sent}
  end

  defp schedule_rebalance(state, _opts) do
    ref = Process.send_after(self(), :rebalance, @rebalance_debounce_ms)
    %{state | rebalance_timer: ref}
  end

  defp fallback_nodes do
    [Node.self() | Node.list()]
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp log_presence_diff(%{joins: joins, leaves: leaves}) do
    Enum.each(Map.keys(joins), fn key ->
      Logger.info("RaftTopology: presence join #{key}")
    end)

    Enum.each(Map.keys(leaves), fn key ->
      Logger.info("RaftTopology: presence leave #{key}")
    end)
  end

  defp cluster_name(group_id), do: String.to_atom("raft_cluster_#{group_id}")

  defp parse_expected_cluster_size do
    # Parse CLUSTER_NODES env to determine expected cluster size
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
end
