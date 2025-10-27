defmodule Fastpaca.Runtime.DrainCoordinator do
  @moduledoc """
  Coordinates graceful Raft shutdown so deployments can leave the cluster without
  dropping committed state.

  On drain we:
    1. Mark the node as `:draining` in presence (traffic avoids us)
    2. Trigger an immediate rebalance so replicas migrate away
    3. Force snapshots for any remaining local groups
    4. Wait for local Ra servers to terminate (membership removal)
  """

  use GenServer
  require Logger

  alias Fastpaca.Observability.Telemetry
  alias Fastpaca.Runtime.{RaftManager, RaftTopology}
  alias Fastpaca.Runtime.RaftTopology.Presence

  @default_drain_timeout :timer.seconds(5)
  @default_grace_period :timer.seconds(1)
  @default_rebalance_timeout :timer.seconds(10)
  @rebalance_poll_interval 100

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Manually trigger a drain. Useful for tests.
  """
  def trigger_drain do
    GenServer.call(__MODULE__, :drain, :infinity)
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)
    Logger.debug("Fastpaca drain coordinator started")
    {:ok, %{draining: false}}
  end

  @impl true
  def handle_call(:drain, _from, %{draining: true} = state) do
    {:reply, {:error, :already_draining}, state}
  end

  def handle_call(:drain, _from, %{draining: false} = state) do
    {:reply, perform_drain(restore?: true), %{state | draining: false}}
  end

  @impl true
  def terminate(reason, _state) do
    if reason in [:shutdown, :normal] do
      Logger.warning("Received shutdown (#{inspect(reason)}), forcing Raft drain")
      perform_drain(restore?: false)
    end

    :ok
  end

  defp perform_drain(opts) do
    restore? = Keyword.get(opts, :restore?, true)
    start_time = System.monotonic_time(:millisecond)

    previous_meta = current_presence_meta()
    mark_draining(previous_meta)
    trigger_rebalance()

    groups = local_groups()
    total = length(groups)

    {snapshot_ok, snapshot_errors} =
      if total == 0 do
        Logger.debug("DrainCoordinator: no local Raft groups to snapshot")
        {0, 0}
      else
        Logger.info("DrainCoordinator: snapshotting #{total} local Raft groups")
        snapshot_groups(groups)
      end

    eviction_timeout =
      Application.get_env(:fastpaca, :drain_rebalance_timeout, @default_rebalance_timeout)

    eviction_result = await_group_eviction(eviction_timeout)

    status =
      cond do
        snapshot_errors == 0 and eviction_result == :ok -> :ok
        eviction_result == :timeout -> :eviction_timeout
        true -> :partial
      end

    elapsed = System.monotonic_time(:millisecond) - start_time

    Telemetry.drain_result(
      status,
      total,
      snapshot_ok,
      snapshot_errors,
      eviction_result,
      elapsed
    )

    maybe_restore_presence(previous_meta, restore?, status)

    finalize_result(status, snapshot_ok, snapshot_errors)
  end

  defp snapshot_groups(groups) do
    tasks =
      Enum.map(groups, fn group_id ->
        Task.async(fn -> snapshot_group(group_id) end)
      end)

    timeout = Application.get_env(:fastpaca, :drain_timeout, @default_drain_timeout)
    results = Task.yield_many(tasks, timeout)
    Enum.each(tasks, &Task.shutdown(&1, :brutal_kill))

    {ok, errors} =
      Enum.reduce(results, {0, 0}, fn
        {_task, {:ok, :ok}}, {succ, fail} -> {succ + 1, fail}
        {_task, {:ok, {:error, _}}}, {succ, fail} -> {succ, fail + 1}
        {_task, nil}, {succ, fail} -> {succ, fail + 1}
        {_task, _other}, {succ, fail} -> {succ, fail + 1}
      end)

    Logger.info(
      "DrainCoordinator: completed snapshots (success=#{ok}/#{length(groups)}, failures=#{errors})"
    )

    grace_period = Application.get_env(:fastpaca, :drain_grace_period, @default_grace_period)

    if grace_period > 0 do
      Process.sleep(grace_period)
    end

    {ok, errors}
  end

  defp await_group_eviction(timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll_eviction(deadline, false)
  end

  defp poll_eviction(deadline, logged?) do
    case local_groups() do
      [] ->
        :ok

      groups ->
        now = System.monotonic_time(:millisecond)

        unless logged? do
          Logger.info(
            "DrainCoordinator: waiting for #{length(groups)} Raft groups to hand off replicas"
          )
        end

        if now >= deadline do
          Logger.warning(
            "DrainCoordinator: timeout waiting for Raft groups to stop (remaining=#{length(groups)})"
          )

          {:error, :timeout}
        else
          Process.sleep(@rebalance_poll_interval)
          poll_eviction(deadline, true)
        end
    end
  end

  defp finalize_result(:ok, _ok, _errors), do: :ok

  defp finalize_result(:partial, ok, errors), do: {:error, {:partial_drain, ok, errors}}

  defp finalize_result(:eviction_timeout, ok, errors),
    do: {:error, {:eviction_timeout, ok, errors}}

  defp local_groups do
    0..(RaftManager.num_groups() - 1)
    |> Enum.filter(fn group_id ->
      server_id = RaftManager.server_id(group_id)
      Process.whereis(server_id) != nil
    end)
  end

  defp snapshot_group(group_id) do
    server_id = RaftManager.server_id(group_id)
    raft_ref = {server_id, Node.self()}

    case :ra.process_command(raft_ref, :force_snapshot, 5_000) do
      {:ok, {:reply, :ok}, _leader} ->
        Logger.debug("DrainCoordinator: snapshot triggered for group #{group_id}")
        :ok

      {:error, :not_leader} ->
        Logger.debug("DrainCoordinator: group #{group_id} not leader, skip snapshot")
        :ok

      {:timeout, leader} ->
        Logger.warning(
          "DrainCoordinator: timeout forcing snapshot for group #{group_id} (leader=#{inspect(leader)})"
        )

        {:error, :timeout}

      {:error, reason} ->
        Logger.warning(
          "DrainCoordinator: failed to snapshot group #{group_id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp mark_draining(nil), do: :ok

  defp mark_draining(meta) do
    ts = timestamp()

    update_presence_meta(Map.merge(meta, %{status: :draining, draining_at: ts, updated_at: ts}))
  end

  defp maybe_restore_presence(nil, _restore?, _status), do: :ok

  defp maybe_restore_presence(meta, true, :ok) do
    ts = timestamp()
    status = Map.get(meta, :status, :ready)

    restored =
      meta
      |> Map.put(:status, status)
      |> Map.delete(:draining_at)
      |> Map.put(:updated_at, ts)
      |> maybe_put_ready_at(status, meta, ts)

    update_presence_meta(restored)
  end

  defp maybe_restore_presence(_meta, _restore?, _status), do: :ok

  defp current_presence_meta do
    case topology_pid() do
      nil ->
        nil

      _pid ->
        key = presence_key()

        RaftTopology.presence_topic()
        |> Presence.list()
        |> Map.get(key)
        |> case do
          %{metas: [meta | _]} -> meta
          _ -> nil
        end
    end
  end

  defp update_presence_meta(meta) when is_map(meta) do
    case topology_pid() do
      nil ->
        :ok

      pid ->
        Presence.update(pid, RaftTopology.presence_topic(), presence_key(), meta)
        :ok
    end
  end

  defp trigger_rebalance do
    if pid = topology_pid() do
      send(pid, :rebalance)
    end
  end

  defp topology_pid do
    Process.whereis(Fastpaca.Runtime.RaftTopology)
  end

  defp presence_key do
    Atom.to_string(Node.self())
  end

  defp timestamp do
    System.system_time(:millisecond)
  end

  defp maybe_put_ready_at(meta, :ready, original_meta, ts) do
    Map.put(meta, :ready_at, Map.get(original_meta, :ready_at, ts))
  end

  defp maybe_put_ready_at(meta, _status, _original_meta, _ts), do: meta
end
