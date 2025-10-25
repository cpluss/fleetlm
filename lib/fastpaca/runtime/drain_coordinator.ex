defmodule Fastpaca.Runtime.DrainCoordinator do
  @moduledoc """
  Forces Raft snapshots during shutdown so deployments persist state.

  When we receive a SIGTERM (or tests call `trigger_drain/0`) we iterate over
  all local Raft groups, issue `:force_snapshot`, and wait for completion with a
  configurable timeout. This keeps restart times short while still running in a
  Raft-only configuration.
  """

  use GenServer
  require Logger

  @default_drain_timeout :timer.seconds(5)
  @default_grace_period :timer.seconds(1)

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
    {:reply, perform_drain(), %{state | draining: false}}
  end

  @impl true
  def terminate(reason, _state) do
    if reason in [:shutdown, :normal] do
      Logger.warning("Received shutdown (#{inspect(reason)}), forcing Raft snapshot drain")
      perform_drain()
    end

    :ok
  end

  defp perform_drain do
    groups = local_groups()
    total = length(groups)

    if total == 0 do
      Logger.debug("DrainCoordinator: no local Raft groups to snapshot")
      :ok
    else
      Logger.info("DrainCoordinator: snapshotting #{total} local Raft groups")

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
        "DrainCoordinator: completed snapshots (success=#{ok}/#{total}, failures=#{errors})"
      )

      grace_period = Application.get_env(:fastpaca, :drain_grace_period, @default_grace_period)

      if grace_period > 0 do
        Process.sleep(grace_period)
      end

      if errors > 0, do: {:error, {:partial_drain, ok, errors}}, else: :ok
    end
  end

  defp local_groups do
    0..(Fastpaca.Runtime.RaftManager.num_groups() - 1)
    |> Enum.filter(fn group_id ->
      server_id = Fastpaca.Runtime.RaftManager.server_id(group_id)
      Process.whereis(server_id) != nil
    end)
  end

  defp snapshot_group(group_id) do
    server_id = Fastpaca.Runtime.RaftManager.server_id(group_id)
    raft_ref = {server_id, Node.self()}

    case :ra.process_command(raft_ref, :force_snapshot, 5_000) do
      {:ok, {:reply, :ok}, _leader} ->
        Logger.debug("DrainCoordinator: snapshot triggered for group #{group_id}")
        :ok

      {:error, :not_leader} ->
        # Followers can ignore – only leaders perform the snapshot.
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
end
