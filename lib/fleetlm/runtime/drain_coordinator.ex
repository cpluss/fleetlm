defmodule Fleetlm.Runtime.DrainCoordinator do
  @moduledoc """
  Coordinates graceful shutdown on SIGTERM.

  ## Raft Architecture

  Much simpler than old WAL architecture:
  1. Trigger snapshots for all 256 Raft groups (parallel)
  2. Wait up to 5s for snapshots to complete
  3. Shutdown

  No per-session draining needed (Raft handles state persistence).
  Snapshots contain:
  - Conversation metadata (hot state)
  - Unflushed message tails
  - Flush watermarks

  On restart: Load snapshot → Replay Raft log → Ready
  """

  use GenServer
  require Logger

  @drain_timeout Application.compile_env(:fleetlm, :drain_timeout, :timer.seconds(5))
  @drain_grace_period Application.compile_env(:fleetlm, :drain_grace_period, :timer.seconds(1))

  # Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Manually trigger drain (useful for testing).

  NOTE: USE WITH CAUTION - THIS WILL BLOCK UNTIL THE DRAIN IS COMPLETED!
  If it is not used correctly it will mess up the sessions.
  """
  def trigger_drain do
    GenServer.call(__MODULE__, :drain, :infinity)
  end

  @doc """
  Reset drain state (for testing only).
  """
  def reset_drain_state do
    GenServer.call(__MODULE__, :reset_drain_state)
  end

  # Server callbacks

  @impl true
  def init(_) do
    # Trap exit to handle SIGTERM gracefully
    Process.flag(:trap_exit, true)

    Logger.debug("DrainCoordinator started, ready to handle SIGTERM")

    {:ok, %{draining: false}}
  end

  @impl true
  def handle_call(:drain, _from, state) do
    if state.draining do
      {:reply, {:error, :already_draining}, state}
    else
      Logger.debug("DrainCoordinator: Starting graceful drain")
      result = perform_drain()
      # Reset draining state after completion (for testing)
      {:reply, result, %{state | draining: false}}
    end
  end

  @impl true
  def handle_call(:reset_drain_state, _from, state) do
    {:reply, :ok, %{state | draining: false}}
  end

  @impl true
  def handle_info({:EXIT, _pid, :normal}, state) do
    # Task completed normally, ignore
    {:noreply, state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warning("DrainCoordinator received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, _state) do
    Logger.debug("DrainCoordinator terminating: #{inspect(reason)}")

    # On SIGTERM, perform graceful drain
    if reason == :shutdown or reason == :normal do
      Logger.warning("Received shutdown signal, initiating graceful drain")
      perform_drain()
    end

    :ok
  end

  # Private helpers

  defp perform_drain do
    start_time = System.monotonic_time(:millisecond)

    Logger.info("DrainCoordinator: Triggering snapshots for local Raft groups")

    # TODO: don't hardcode 256 groups
    groups_to_snapshot =
      0..255
      |> Enum.filter(fn group_id ->
        server_id = Fleetlm.Runtime.RaftManager.server_id(group_id)
        Process.whereis(server_id) != nil
      end)

    total = length(groups_to_snapshot)

    # Trigger snapshots for all groups in parallel
    tasks =
      for group_id <- groups_to_snapshot do
        Task.async(fn -> snapshot_group(group_id) end)
      end

    # Wait for all snapshots to complete or timeout
    results = Task.yield_many(tasks, @drain_timeout)

    # Count successes and failures
    {successes, failures} =
      Enum.reduce(results, {0, 0}, fn {_task, result}, {succ, fail} ->
        case result do
          {:ok, :ok} -> {succ + 1, fail}
          {:ok, {:error, _}} -> {succ, fail + 1}
          # Timeout
          nil -> {succ, fail + 1}
          _ -> {succ, fail + 1}
        end
      end)

    # Shutdown any tasks that didn't complete
    Enum.each(tasks, &Task.shutdown(&1, :brutal_kill))

    elapsed = System.monotonic_time(:millisecond) - start_time

    Logger.info(
      "DrainCoordinator: Completed drain in #{elapsed}ms - " <>
        "#{successes}/#{total} groups snapshotted, #{failures} failures"
    )

    # Emit telemetry
    Fleetlm.Observability.Telemetry.emit_session_drain(
      :shutdown,
      total,
      successes,
      failures,
      elapsed
    )

    # Give a brief grace period for final cleanup
    if @drain_grace_period > 0 do
      Process.sleep(@drain_grace_period)
    end

    if failures > 0 do
      {:error, {:partial_drain, successes, failures}}
    else
      :ok
    end
  end

  defp snapshot_group(group_id) do
    server_id = Fleetlm.Runtime.RaftManager.server_id(group_id)
    raft_ref = {server_id, Node.self()}

    case :ra.process_command(raft_ref, :force_snapshot, 5_000) do
      {:ok, {:reply, :ok}, _leader} ->
        Logger.debug("Snapshot triggered for group #{group_id}")
        :ok

      {:error, :not_leader} ->
        # Expected on followers, not an error
        Logger.debug("Group #{group_id}: Not leader, skip snapshot")
        :ok

      {:timeout, leader} ->
        Logger.warning(
          "Snapshot command timed out for group #{group_id}: leader=#{inspect(leader)}"
        )

        {:error, :timeout}

      {:error, reason} ->
        Logger.warning("Failed to snapshot group #{group_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
