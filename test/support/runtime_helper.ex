defmodule Fleetlm.Runtime.TestHelper do
  @moduledoc false

  alias Fleetlm.Runtime.InboxSupervisor

  require ExUnit.CaptureLog
  require Logger

  def reset do
    ExUnit.CaptureLog.capture_log(fn ->
      # Terminate InboxServer processes
      terminate_children_forcefully(Fleetlm.Runtime.InboxRegistry, InboxSupervisor)

      # Cleanup Raft data directory (test mode only)
      cleanup_raft_test_data()

      # Brief wait to ensure all database operations complete
      Process.sleep(25)
    end)

    :ok
  end

  defp cleanup_raft_test_data do
    test_data_dir = Application.get_env(:fleetlm, :raft_data_dir, "tmp/test_raft")

    if String.contains?(test_data_dir, "test") do
      File.rm_rf(test_data_dir)
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
