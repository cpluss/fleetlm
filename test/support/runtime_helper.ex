defmodule Fleetlm.Runtime.TestHelper do
  @moduledoc false

  alias Fleetlm.Runtime.Cache
  alias Fleetlm.Runtime.SessionSupervisor
  alias Fleetlm.Runtime.InboxSupervisor

  def reset do
    # Terminate children forcefully but safely
    terminate_children_forcefully(Fleetlm.Runtime.SessionRegistry, SessionSupervisor)
    terminate_children_forcefully(Fleetlm.Runtime.InboxRegistry, InboxSupervisor)

    # Reset caches after all processes have terminated
    _ = Cache.reset()

    # Brief wait to ensure all database operations complete
    Process.sleep(25)
    :ok
  end

  defp terminate_children_forcefully(_registry, supervisor) do
    if Code.ensure_loaded?(supervisor) do
      case Process.whereis(supervisor) do
        nil ->
          :ok

        _ ->
          children = DynamicSupervisor.which_children(supervisor)

          # Terminate all children forcefully using supervisor terminate_child
          children
          |> Enum.each(fn {_id, pid, _type, _modules} ->
            if Process.alive?(pid) do
              # Use supervisor's terminate_child which is forceful but safe
              DynamicSupervisor.terminate_child(supervisor, pid)
            end
          end)
      end
    else
      :ok
    end
  end
end
