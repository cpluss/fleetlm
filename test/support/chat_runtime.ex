defmodule Fleetlm.Chat.TestRuntime do
  @moduledoc false

  alias Fleetlm.Sessions.Cache
  alias Fleetlm.Sessions.SessionSupervisor
  alias Fleetlm.Sessions.InboxSupervisor

  def reset do
    terminate_children(Fleetlm.Sessions.SessionRegistry, SessionSupervisor)
    terminate_children(Fleetlm.Sessions.InboxRegistry, InboxSupervisor)
    _ = Cache.reset()
    :ok
  end

  defp terminate_children(_registry, supervisor) do
    if Code.ensure_loaded?(supervisor) do
      case Process.whereis(supervisor) do
        nil ->
          :ok

        _ ->
          supervisor
          |> DynamicSupervisor.which_children()
          |> Enum.each(fn {_id, pid, _type, _modules} ->
            if Process.alive?(pid) do
              DynamicSupervisor.terminate_child(supervisor, pid)
            end
          end)
      end
    else
      :ok
    end
  end
end
