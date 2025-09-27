defmodule Fleetlm.Chat.TestRuntime do
  @moduledoc false

  alias Fleetlm.Sessions.Cache
  alias Fleetlm.Sessions.SessionSupervisor
  alias Fleetlm.Sessions.InboxSupervisor

  def reset do
    # Gracefully terminate children and wait for completion
    terminate_children(Fleetlm.Sessions.SessionRegistry, SessionSupervisor)
    terminate_children(Fleetlm.Sessions.InboxRegistry, InboxSupervisor)

    # Reset caches
    _ = Cache.reset()

    # Allow all async operations to complete before test ends
    Process.sleep(20)
    :ok
  end

  defp terminate_children(_registry, supervisor) do
    if Code.ensure_loaded?(supervisor) do
      case Process.whereis(supervisor) do
        nil ->
          :ok

        _ ->
          children = DynamicSupervisor.which_children(supervisor)

          # Terminate all children and wait for them to finish
          children
          |> Enum.each(fn {_id, pid, _type, _modules} ->
            if Process.alive?(pid) do
              DynamicSupervisor.terminate_child(supervisor, pid)
              # Wait for process to actually terminate
              ref = Process.monitor(pid)
              receive do
                {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
              after
                200 -> :ok  # Wait longer for graceful shutdown
              end
            end
          end)
      end
    else
      :ok
    end
  end
end
