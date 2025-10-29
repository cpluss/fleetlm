defmodule Fastpaca.Runtime.RaftTopology do
  @moduledoc """
  Coordinates Raft membership across the cluster, inspired by Horde.

  Raft is amazing but unfortunately doesn't manage the dynamic membership
  of a cluster for us, so we have to do that ourselves. As we're most
  likely running on a dynamic pool of replicas (over 3 nodes) and we
  want to support rolling releases (one node down, one node up) we
  need to be elastic. The topology mechanism is exactly how we achieve
  that.

  ## Responsibilities

  - Track cluster membership via Presence (CRDT gossip)
  - Wait for libcluster formation before starting groups
  - Start assigned Raft groups async via Task.Supervisor
  - Rebalance groups when nodes join/leave (add_member/remove_member)
  - Gate traffic: track as :joining, update to :ready when done, to
    avoid premature errors because we're not ready.

  ## Dynamic Membership

  - Presence.list() = all nodes (joining + ready) → used for placement
  - Coordinator election: lowest node in ready_nodes() rebalances
  - Rebalance: diff Ra.members vs desired, execute adds then removes
  """

  use GenServer
  require Logger

  alias Fastpaca.Runtime.RaftManager

  @presence_topic "fastpaca:raft_ready_nodes"
  # TODO: make these configurable
  @rebalance_debounce_ms 5_000
  @readiness_interval_ms 1_000

  @doc false
  def presence_topic, do: @presence_topic

  defmodule Presence do
    @moduledoc """
    We use phoenix presence as a CRDT to maintain a list of nodes available / seen / present
    in the cluster itself. It allows us to detect when a node is ready and is fully operational
    such that we can signal this on the health endpoint, and not accept traffic until we are
    ready for it (joined the cluster).
    """
    use Phoenix.Presence,
      otp_app: :fastpaca,
      pubsub_server: Fastpaca.PubSub
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
    |> Enum.map(& &1[:node])
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
    |> Enum.map(& &1[:node])
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

    # Suppress Ra's verbose logs - only show errors
    :logger.set_application_level(:ra, :error)

    :ok = Phoenix.PubSub.subscribe(Fastpaca.PubSub, @presence_topic)
    :ok = :net_kernel.monitor_nodes(true, node_type: :visible)

    # CRITICAL: Track immediately as :joining so placement can see us!
    node_key = Atom.to_string(Node.self())
    meta = %{node: Node.self(), status: :joining, started_at: System.system_time(:millisecond)}

    case Presence.track(self(), @presence_topic, node_key, meta) do
      {:ok, _} -> :ok
      {:error, {:already_tracked, _}} -> :ok
    end

    Logger.debug("RaftTopology: starting in joining state on #{Node.self()}")

    Process.send_after(self(), :check_readiness, @readiness_interval_ms)

    {:ok,
     %{
       status: :joining,
       rebalance_timer: nil,
       formation: true
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
  def handle_info(:check_readiness, %{formation: true} = state) do
    # During initial formation, wait for a minimal quorum of nodes, not full CLUSTER_NODES.
    expected_nodes = parse_expected_cluster_size()
    current_cluster = [Node.self() | Node.list()] |> length()
    replication_factor = 3
    min_quorum = min(expected_nodes, replication_factor)

    if current_cluster < min_quorum do
      Logger.debug(
        "RaftTopology: waiting for cluster (#{current_cluster}/#{min_quorum} nodes connected)"
      )
      Process.send_after(self(), :check_readiness, @readiness_interval_ms)
      {:noreply, state}
    else
      my_groups = compute_my_groups()

      not_started = Enum.reject(my_groups, &group_running?/1)

      unless Enum.empty?(not_started) do
        Logger.debug("RaftTopology: Starting #{length(not_started)} groups asynchronously...")

        # Start groups async via Task.Supervisor in a non-blocking way
        Task.Supervisor.async_stream_nolink(
          Fastpaca.RaftTaskSupervisor,
          not_started,
          fn group_id -> RaftManager.start_group(group_id) end,
          max_concurrency: 50,
          timeout: 30_000
        )
        |> Stream.run()
      end

      if Enum.all?(my_groups, &joined_group?/1) do
        Logger.debug("RaftTopology: joined #{length(my_groups)} groups; marking ready")
        mark_ready()
        schedule_rebalance(state, immediate: true)
        {:noreply, %{state | status: :ready, formation: false}}
      else
        Logger.debug(
          "RaftTopology: joined #{Enum.count(my_groups, &joined_group?/1)}/#{length(my_groups)} groups"
        )

        Process.send_after(self(), :check_readiness, @readiness_interval_ms)
        {:noreply, %{state | status: :joining}}
      end
    end
  end

  # After initial formation, never gate on expected cluster size again.
  @impl true
  def handle_info(:check_readiness, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:nodeup, node, _info}, state) do
    Logger.debug("RaftTopology: node up #{inspect(node)}")
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
        Logger.debug("RaftTopology: coordinating rebalance across #{length(ready)} ready nodes")
        Enum.each(0..255, &rebalance_group(&1, ready))
        Logger.debug("RaftTopology: rebalance complete")

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
    # Use Node.list() directly during boot (Presence lags behind libcluster!)
    # After nodes are ready, rebalance will use all_nodes() from Presence
    candidates = [Node.self() | Node.list()] |> Enum.uniq() |> Enum.sort()

    for group_id <- 0..255,
        Node.self() in rendezvous_select(candidates, group_id),
        do: group_id
  end

  # (no sentinel groups)

  defp group_running?(group_id) do
    Process.whereis(RaftManager.server_id(group_id)) != nil
  end

  defp joined_group?(group_id) do
    server_id = RaftManager.server_id(group_id)
    my_server = {server_id, Node.self()}

    case Process.whereis(server_id) do
      nil ->
        false

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
          Logger.warning(
            "Rebalancing group #{group_id}: +#{length(to_add)} -#{length(to_remove)}"
          )
        end

        # Add members first, then wait for commit, then remove
        unless Enum.empty?(to_add) do
          # Determine current leader; propose membership on the leader when known
          leader_target =
            case :ra.members(ref) do
              {:ok, _cur, leader_ref} when not is_nil(leader_ref) -> leader_ref
              _ -> ref
            end

          Enum.each(to_add, fn member -> add_member(group_id, leader_target, member) end)

          # Poll until adds are committed (no blind sleeps!)
          case wait_for_membership_change(ref, desired, timeout_ms: 10000) do
            :ok ->
              Logger.debug("RaftTopology: adds committed for group #{group_id}")

            :timeout ->
              Logger.warning(
                "RaftTopology: timeout waiting for adds to commit for group #{group_id}"
              )
          end
        end

        # Only remove after adds are fully committed (robust guard)
        # Re-evaluate leader before removals
        leader_for_remove =
          case :ra.members(ref) do
            {:ok, _cur2, leader2} when not is_nil(leader2) -> leader2
            _ -> ref
          end

        Enum.each(to_remove, fn member -> remove_member(group_id, leader_for_remove, member) end)

      {:error, :noproc} ->
        :ok

      {:error, reason} ->
        Logger.debug(
          "RaftTopology: cannot fetch members for group #{group_id}: #{inspect(reason)}"
        )

      {:timeout, _} ->
        Logger.debug("RaftTopology: timeout fetching members for group #{group_id}")
    end

    :ok
  end

  defp add_member(group_id, leader_ref, {server_id, node} = member) do
    Logger.debug("RaftTopology: adding #{inspect(node)} to group #{group_id}")

    # Ensure group is started on the target first
    _ = :rpc.call(node, RaftManager, :start_group, [group_id])

    # Propose on leader (or fallback ref)
    case :ra.add_member(leader_ref, member) do
      {:ok, _members, _leader} ->
        Logger.debug("RaftTopology: added #{inspect(node)} to group #{group_id}")
        :ok

      {:error, :not_leader} ->
        Logger.debug("RaftTopology: add_member not_leader for group #{group_id}")
        :ok

      {:error, reason} ->
        Logger.warning(
          "RaftTopology: failed to add #{inspect(node)} to group #{group_id}: #{inspect(reason)}"
        )

        {:error, reason}

      {:timeout, _} ->
        Logger.warning("RaftTopology: timeout adding #{inspect(node)} to group #{group_id}")
        {:error, :timeout}
    end
  end

  defp remove_member(group_id, leader_ref, {server_id, node} = member) do
    Logger.debug("RaftTopology: removing #{inspect(node)} from group #{group_id}")

    case :ra.remove_member(leader_ref, member) do
      {:ok, _members, _leader} ->
        Logger.debug("RaftTopology: removed #{inspect(node)} from group #{group_id}")
        :rpc.call(node, :ra, :stop_server, [:default, {server_id, node}])
        :ok

      {:error, :not_leader} ->
        Logger.debug("RaftTopology: remove_member not_leader for group #{group_id}")
        :ok

      {:error, reason} ->
        Logger.warning(
          "RaftTopology: failed to remove #{inspect(node)} from group #{group_id}: #{inspect(reason)}"
        )

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

  defp schedule_rebalance(%{rebalance_timer: ref} = state, _opts)
       when is_reference(ref) or ref == :sent do
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

  defp log_presence_diff(%{joins: joins, leaves: leaves}) do
    Enum.each(Map.keys(joins), fn key ->
      Logger.debug("RaftTopology: presence join #{key}")
    end)

    Enum.each(Map.keys(leaves), fn key ->
      Logger.debug("RaftTopology: presence leave #{key}")
    end)
  end

  defp cluster_name(group_id), do: String.to_atom("raft_cluster_#{group_id}")

  defp wait_for_membership_change(server_ref, desired_members, timeout_ms: timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    poll_membership(server_ref, desired_members, deadline)
  end

  defp poll_membership(server_ref, desired_members, deadline) do
    if System.monotonic_time(:millisecond) > deadline do
      Logger.warning("RaftTopology: Timeout waiting for membership change")
      :timeout
    else
      case :ra.members(server_ref) do
        {:ok, current, _leader} ->
          # Check if all desired members are now in current
          if Enum.all?(desired_members, &(&1 in current)) do
            :ok
          else
            # Retry backoff
            Process.sleep(50)
            poll_membership(server_ref, desired_members, deadline)
          end

        _ ->
          Process.sleep(50)
          poll_membership(server_ref, desired_members, deadline)
      end
    end
  end

  defp parse_expected_cluster_size do
    # Parse CLUSTER_NODES env to determine expected cluster size
    case System.get_env("CLUSTER_NODES") do
      nil ->
        1

      "" ->
        1

      nodes_str ->
        nodes_str
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
        |> length()
    end
  end
end
