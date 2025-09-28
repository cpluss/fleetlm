defmodule Fleetlm.TestSupport.Sharding do
  @moduledoc false

  import ExUnit.Assertions

  require Logger

  alias Fleetlm.Runtime.Sharding.{SlotServer, Slots}

  require ExUnit.CaptureLog

  @registry Fleetlm.Runtime.Sharding.LocalRegistry

  @default_attempts 40

  @doc """
  Ensure the shard for the given slot is running and return its PID.

  The slot process is allowed to access the SQL sandbox so callers can issue
  queries without hitting ownership errors.
  """
  def ensure_slot!(slot, opts \\ []) when is_integer(slot) do
    attempts = Keyword.get(opts, :attempts, @default_attempts)

    wait_for_registry()

    pid =
      suppress_log(fn ->
        case safe_ensure_slot_started(slot, attempts) do
          :ok ->
            lookup_slot!(slot, attempts)

          {:ok, pid} when is_pid(pid) ->
            pid

          {:error, reason} ->
            start_slot_direct!(slot, reason, attempts)
        end
      end)

    Fleetlm.DataCase.allow_sandbox_access(pid)
    pid
  end

  @doc """
  Fetch the PID for the given slot, failing the test if it cannot be located.
  """
  def slot_pid!(slot, opts \\ []) when is_integer(slot) do
    attempts = Keyword.get(opts, :attempts, @default_attempts)

    case lookup_slot(slot, attempts) do
      nil -> flunk("slot #{slot} did not start")
      pid -> pid
    end
  end

  @doc """
  Force a slot to restart and return the new PID.

  By default the slot process is stopped gracefully. Passing
  `:kill` will simulate an abrupt crash, while `:rebalance` issues a
  `SlotServer.rebalance/1` instead.
  """
  def restart_slot!(slot, action \\ :stop, opts \\ []) when is_integer(slot) do
    case lookup_slot(slot, 5) do
      nil -> :ok
      pid -> terminate_slot(pid, slot, action)
    end

    ensure_slot!(slot, opts)
  end

  @doc """
  Terminate the slot abruptly (alias for `restart_slot!/3` with `:kill`).
  """
  def kill_slot!(slot, opts \\ []) when is_integer(slot) do
    restart_slot!(slot, :kill, opts)
  end

  @doc """
  Crash the slot without immediately restarting it. Useful for tests that need
  to observe recovery behaviour after a hard failure.
  """
  def crash_slot!(slot) when is_integer(slot) do
    pid = slot_pid!(slot)

    suppress_log(fn ->
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      await_down(ref)
    end)

    pid
  end

  defp terminate_slot(pid, slot, :stop) do
    suppress_log(fn ->
      SlotServer.stop(slot)
      await_down(pid)
    end)
  end

  defp terminate_slot(pid, slot, :rebalance) do
    suppress_log(fn ->
      SlotServer.rebalance(slot)
      await_down(pid)
    end)
  end

  defp terminate_slot(pid, _slot, :kill) do
    suppress_log(fn ->
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      await_down(ref)
    end)
  end

  defp terminate_slot(pid, _slot, {:exit, reason}) do
    suppress_log(fn ->
      ref = Process.monitor(pid)
      Process.exit(pid, reason)
      await_down(ref)
    end)
  end

  defp terminate_slot(pid, _slot, fun) when is_function(fun, 1) do
    suppress_log(fn ->
      ref = Process.monitor(pid)
      _ = fun.(pid)
      await_down(ref)
    end)
  end

  defp safe_ensure_slot_started(slot, attempts) do
    suppress_log(fn -> Slots.ensure_slot_started(slot) end)
  rescue
    ArgumentError ->
      retry_after_registry(slot, attempts)
  catch
    :exit, {:noproc, _} ->
      retry_start_child(slot, attempts)
  end

  defp retry_after_registry(slot, attempts) when attempts > 0 do
    wait_for_registry()
    safe_ensure_slot_started(slot, attempts - 1)
  end

  defp retry_after_registry(_slot, _attempts), do: {:error, :registry_unavailable}

  defp retry_start_child(slot, attempts) when attempts > 0 do
    Process.sleep(50)
    safe_ensure_slot_started(slot, attempts - 1)
  end

  defp retry_start_child(_slot, _attempts), do: {:error, :supervisor_unavailable}

  defp start_slot_direct!(slot, reason, attempts) when attempts > 0 do
    Logger.debug("Falling back to SlotServer.start_link for slot #{slot}: #{inspect(reason)}")

    suppress_log(fn ->
      case SlotServer.start_link(slot) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
        {:error, {:already_present, pid}} -> pid
        {:error, reason} -> start_slot_direct!(slot, reason, attempts - 1)
      end
    end)
  rescue
    ArgumentError ->
      wait_for_registry()
      start_slot_direct!(slot, reason, attempts - 1)
  end

  defp start_slot_direct!(_slot, reason, _attempts) do
    flunk("unable to start slot: #{inspect(reason)}")
  end

  defp lookup_slot!(slot, attempts) do
    case lookup_slot(slot, attempts) do
      nil -> flunk("slot #{slot} did not start")
      pid -> pid
    end
  end

  defp lookup_slot(slot, attempts) when attempts > 0 do
    wait_for_registry()

    case Registry.lookup(@registry, {:shard, slot}) do
      [{pid, _}] when is_pid(pid) ->
        pid

      [] ->
        Process.sleep(25)
        lookup_slot(slot, attempts - 1)
    end
  rescue
    ArgumentError ->
      Process.sleep(25)
      lookup_slot(slot, attempts - 1)
  end

  defp lookup_slot(_slot, _attempts), do: nil

  defp wait_for_registry(attempts \\ @default_attempts)

  defp wait_for_registry(0), do: :ok

  defp wait_for_registry(attempts) do
    case Process.whereis(@registry) do
      nil ->
        Process.sleep(25)
        wait_for_registry(attempts - 1)

      _pid ->
        :ok
    end
  end

  defp await_down(ref) when is_reference(ref) do
    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> :ok
    after
      1_000 -> :ok
    end
  end

  defp await_down(pid) when is_pid(pid) do
    ref = Process.monitor(pid)
    await_down(ref)
  end

  defp suppress_log(fun) when is_function(fun, 0) do
    ref = make_ref()
    parent = self()

    ExUnit.CaptureLog.capture_log(fn ->
      result = fun.()
      send(parent, {ref, result})
    end)

    receive do
      {^ref, result} -> result
    end
  end
end
