defmodule Fleetlm.Runtime.DrainCoordinator do
  @moduledoc """
  Coordinates graceful shutdown on SIGTERM.

  Responsibilities:
  - Listen for SIGTERM signal
  - Drain all active SessionServer processes
  - Ensure messages are flushed to database
  - Mark sessions as inactive
  - Timeout protection (max 30 seconds)

  This is critical for zero-downtime deployments.
  """

  use GenServer
  require Logger

  @drain_timeout :timer.seconds(30)
  @drain_grace_period :timer.seconds(2)

  # Client API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Manually trigger drain (useful for testing).
  """
  def trigger_drain do
    GenServer.call(__MODULE__, :drain, :infinity)
  end

  # Server callbacks

  @impl true
  def init(_) do
    # Trap exit to handle SIGTERM gracefully
    Process.flag(:trap_exit, true)

    Logger.info("DrainCoordinator started, ready to handle SIGTERM")

    {:ok, %{draining: false}}
  end

  @impl true
  def handle_call(:drain, _from, state) do
    if state.draining do
      {:reply, {:error, :already_draining}, state}
    else
      Logger.warning("DrainCoordinator: Starting graceful drain")
      result = perform_drain()
      {:reply, result, %{state | draining: true}}
    end
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
    Logger.info("DrainCoordinator terminating: #{inspect(reason)}")

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

    # Get all active session servers
    active_sessions = get_active_sessions()

    Logger.info("DrainCoordinator: Draining #{length(active_sessions)} active sessions")

    # Drain each session in parallel with timeout
    tasks =
      active_sessions
      |> Enum.map(fn session_id ->
        Task.async(fn ->
          drain_session_with_timeout(session_id)
        end)
      end)

    # Wait for all drains to complete or timeout
    results = Task.yield_many(tasks, @drain_timeout)

    # Count successes and failures
    {successes, failures} =
      Enum.reduce(results, {0, 0}, fn {_task, result}, {succ, fail} ->
        case result do
          {:ok, :ok} -> {succ + 1, fail}
          {:ok, {:error, _}} -> {succ, fail + 1}
          nil -> {succ, fail + 1}  # Timeout
          _ -> {succ, fail + 1}
        end
      end)

    # Shutdown any tasks that didn't complete
    Enum.each(tasks, &Task.shutdown(&1, :brutal_kill))

    elapsed = System.monotonic_time(:millisecond) - start_time

    Logger.info(
      "DrainCoordinator: Completed drain in #{elapsed}ms - " <>
        "#{successes} succeeded, #{failures} failed/timed out"
    )

    # Give a brief grace period for final cleanup
    Process.sleep(@drain_grace_period)

    if failures > 0 do
      {:error, {:partial_drain, successes, failures}}
    else
      :ok
    end
  end

  defp get_active_sessions do
    # Get all active session servers from registry
    case Process.whereis(Fleetlm.Runtime.SessionRegistry) do
      nil ->
        []

      _pid ->
        Registry.select(Fleetlm.Runtime.SessionRegistry, [{{:"$1", :_, :_}, [], [:"$1"]}])
    end
  end

  defp drain_session_with_timeout(session_id) do
    try do
      case Fleetlm.Runtime.SessionServer.drain(session_id) do
        :ok ->
          Logger.debug("Successfully drained session #{session_id}")
          :ok

        {:error, reason} = error ->
          Logger.error("Failed to drain session #{session_id}: #{inspect(reason)}")
          error
      end
    catch
      :exit, {:noproc, _} ->
        # Session already stopped
        :ok

      kind, reason ->
        Logger.error("Error draining session #{session_id}: #{kind} #{inspect(reason)}")
        {:error, {kind, reason}}
    end
  end
end