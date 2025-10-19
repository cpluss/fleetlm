defmodule Fleetlm.Runtime.RaftManager do
  @moduledoc """
  Manages Raft groups for distributed message storage.

  ## Architecture

  - 256 Raft groups total across cluster
  - Each group: 3 replicas (2-of-3 quorum, same AZ)
  - Each group: 16 lanes for parallel writes
  - Placement: Rendezvous (HRW) hashing for deterministic replica selection

  ## Startup

  On node boot:
  1. Determine which groups this node should participate in
  2. Start Ra servers for those groups
  3. Join existing Raft clusters or bootstrap new ones

  ## Routing

  - session_id → group: phash2(session_id, 256)
  - session_id → lane: phash2(session_id, 16)
  - Any node can propose to any group (leader forwards internally)
  """

  use GenServer
  require Logger

  alias Fleetlm.Runtime.RaftFSM

  @num_groups 256
  @replication_factor 3
  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Get the Raft group ID for a session"
  def group_for_session(session_id) do
      # TODO: replace with consistent hashing algo
    :erlang.phash2(session_id, @num_groups)
  end

  @doc "Get the lane ID for a session within its group"
  def lane_for_session(session_id) do
    # TODO: replace with consistent hashing algo
    :erlang.phash2(session_id, 16)
  end

  @doc "Get the Ra server ID for a group"
  def server_id(group_id) do
    # Must be an atom for Ra's process registration
    String.to_atom("raft_group_#{group_id}")
  end

  @doc "Get all Ra server IDs for a group across all replicas"
  def cluster_members(group_id) do
    for node <- replicas_for_group(group_id) do
      {server_id(group_id), node}
    end
  end

  @spec replicas_for_group(any()) :: list()
  @doc "Determine which nodes should host replicas for a group"
  def replicas_for_group(group_id) do
    current_nodes()
    |> Enum.map(fn node ->
      # TODO: replace with consistent hashing algo
      score = :erlang.phash2({group_id, node})
      {score, node}
    end)
    |> Enum.sort()
    |> Enum.take(@replication_factor)
    |> Enum.map(fn {_, node} -> node end)
  end

  @doc "Check if this node should participate in a group"
  def should_participate?(group_id) do
    Node.self() in replicas_for_group(group_id)
  end

  @doc """
  Ensure a Raft group is started (lazy initialization for test mode).

  In production: groups are pre-started in init/1.
  In test: groups are started on-demand to avoid initializing all 256 groups.
  """
  def ensure_started(group_id) do
    case raft_mode() do
      :test ->
        # Lazy start in test mode
        ensure_group_started(group_id)

      _ ->
        # In production, groups are already started
        {:ok, :already_started}
    end
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    # Ensure Ra is started
    case :ra.start() do
      :ok -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    case raft_mode() do
      :test ->
        # Test mode: lazy initialization (start groups on-demand)
        Logger.info("RaftManager: Test mode - using lazy group initialization")
        {:ok, %{started_groups: MapSet.new()}}

      _ ->
        # Production mode: start all groups upfront
        groups_to_start = for g <- 0..(@num_groups - 1), should_participate?(g), do: g

        Logger.info(
          "RaftManager: Starting #{length(groups_to_start)} Raft groups on node #{Node.self()}"
        )

        Enum.each(groups_to_start, &start_group/1)

        {:ok, %{started_groups: MapSet.new(groups_to_start)}}
    end
  end

  @impl true
  def handle_call({:ensure_started, group_id}, _from, state) do
    if MapSet.member?(state.started_groups, group_id) do
      {:reply, {:ok, :already_started}, state}
    else
      case start_group(group_id) do
        :ok ->
          {:reply, {:ok, :started}, %{state | started_groups: MapSet.put(state.started_groups, group_id)}}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private helpers

  defp ensure_group_started(group_id) do
    GenServer.call(__MODULE__, {:ensure_started, group_id}, 10_000)
  end

  defp raft_mode do
    Application.get_env(:fleetlm, :raft_mode, :production)
  end

  defp start_group(group_id) do
    server_id = server_id(group_id)
    my_node = Node.self()
    my_server_id = {server_id, my_node}

    # Cluster name must be an atom
    cluster_name = String.to_atom("raft_cluster_#{group_id}")

    # Build machine config (tuple format for behavior-based machines)
    machine = machine(group_id)

    # Get all replicas for this group (3 nodes in production, 1 in test)
    replica_nodes = replicas_for_group(group_id)
    server_ids = for node <- replica_nodes, do: {server_id, node}

    Logger.info(
      "Starting Raft group #{group_id} with #{length(server_ids)} replicas: #{inspect(replica_nodes)}"
    )

    # Ra's start_cluster/4 takes: (System, ClusterName, Machine, ServerIds)
    # System is :default for the default Ra system
    case :ra.start_cluster(:default, cluster_name, machine, server_ids) do
      {:ok, started, not_started} ->
        # Check if THIS node started successfully
        cond do
          my_server_id in started ->
            Logger.info("Raft group #{group_id}: Started as part of cluster")
            :ok

          my_server_id in not_started ->
            # We're in the member list but didn't start - join now
            Logger.info("Raft group #{group_id}: Not started in initial bootstrap, joining now")
            join_as_follower(group_id, server_id, cluster_name, machine)

          true ->
            # Shouldn't happen - we're not in the member list at all
            Logger.warning("Raft group #{group_id}: This node not in member list, skipping")
            :ok
        end

      {:error, {:already_started, _leader}} ->
        # Cluster already exists on another node - join it
        Logger.info("Raft group #{group_id}: Cluster exists, joining as follower")
        join_as_follower(group_id, server_id, cluster_name, machine)

      {:error, reason} ->
        Logger.error("Failed to start Raft group #{group_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp join_as_follower(group_id, server_id, cluster_name, machine) do
    my_node = Node.self()
    node_name = my_node |> Atom.to_string() |> String.replace(~r/[^a-zA-Z0-9_]/, "_")

    # Ensure data directory exists
    data_dir_root = Application.get_env(:fleetlm, :raft_data_dir, "priv/raft")
    # Keep per-node Ra log directories so replicas don't trample each other
    data_dir = Path.join([data_dir_root, "group_#{group_id}", node_name])
    File.mkdir_p!(data_dir)

    server_conf = %{
      id: {server_id, my_node},
      uid: "raft_group_#{group_id}_#{node_name}",
      cluster_name: cluster_name,
      log_init_args: %{
        uid: "raft_log_#{group_id}_#{node_name}",
        data_dir: data_dir
      },
      machine: machine
    }

    case :ra.start_server(:default, server_conf) do
      :ok ->
        Logger.info("Raft group #{group_id}: Joined as follower on #{my_node}")
        :ok

      {:ok, _pid} ->
        Logger.info("Raft group #{group_id}: Joined as follower on #{my_node}")
        :ok

      {:error, {:already_started, _}} ->
        # Already running locally, that's fine
        Logger.debug("Raft group #{group_id}: Already running on #{my_node}")
        :ok

      {:error, reason} ->
        Logger.error("Failed to join Raft group #{group_id} as follower: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp current_nodes do
    [Node.self() | Node.list()]
    |> Enum.uniq()
    |> Enum.sort()
  end

  # Ra machine definition

  @doc false
  def machine(group_id) do
    # Use tuple format for behavior-based machines
    # Config MUST be a map (Ra requirement)
    {:module, RaftFSM, %{group_id: group_id}}
  end
end
