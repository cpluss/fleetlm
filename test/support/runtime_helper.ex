defmodule Fleetlm.Runtime.TestHelper do
  @moduledoc false

  alias Fleetlm.Runtime.SessionSupervisor
  alias Fleetlm.Runtime.InboxSupervisor
  alias FleetLM.Storage.Supervisor, as: StorageSupervisor

  require ExUnit.CaptureLog
  require Logger

  def reset do
    ExUnit.CaptureLog.capture_log(fn ->
      # Terminate children forcefully but safely
      terminate_children_forcefully(Fleetlm.Runtime.SessionRegistry, SessionSupervisor)
      terminate_children_forcefully(Fleetlm.Runtime.InboxRegistry, InboxSupervisor)
      cleanup_slot_servers()

      # Brief wait to ensure all database operations complete
      Process.sleep(25)
    end)

    :ok
  end

  defp cleanup_slot_servers do
    if Code.ensure_loaded?(StorageSupervisor) and Process.whereis(StorageSupervisor) do
      StorageSupervisor.active_slots()
      |> Enum.each(fn slot ->
        case StorageSupervisor.flush_slot(slot) do
          {:error, reason} ->
            Logger.warning("Failed to flush slot #{slot} during test cleanup: #{inspect(reason)}")
          _ ->
            :ok
        end

        case StorageSupervisor.stop_slot(slot) do
          {:error, reason} ->
            Logger.warning("Failed to stop slot #{slot} during test cleanup: #{inspect(reason)}")
          _ ->
            :ok
        end
      end)
    end
  end

  defp terminate_children_forcefully(_registry, supervisor) do
    if Code.ensure_loaded?(supervisor) do
      case Process.whereis(supervisor) do
        nil ->
          :ok

        _ ->
          children = DynamicSupervisor.which_children(supervisor)

          # Monitor all children first, then terminate and wait for DOWN messages
          monitored_children =
            children
            |> Enum.filter(fn {_id, pid, _type, _modules} -> Process.alive?(pid) end)
            |> Enum.map(fn {_id, pid, _type, _modules} ->
              ref = Process.monitor(pid)
              {pid, ref}
            end)

          # Terminate all children
          monitored_children
          |> Enum.each(fn {pid, _ref} ->
            DynamicSupervisor.terminate_child(supervisor, pid)
          end)

          # Wait for all DOWN messages with timeout
          monitored_children
          |> Enum.each(fn {_pid, ref} ->
            receive do
              {:DOWN, ^ref, :process, _, _} -> :ok
            after
              5000 -> :ok
            end
          end)
      end
    else
      :ok
    end
  end
end
