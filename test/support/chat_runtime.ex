defmodule Fleetlm.Chat.TestRuntime do
  @moduledoc false

  def reset do
    terminate_children(Fleetlm.Chat.ConversationRegistry, Fleetlm.Chat.ConversationSupervisor)
    terminate_children(Fleetlm.Chat.InboxRegistry, Fleetlm.Chat.InboxSupervisor)
  end

  defp terminate_children(_registry, supervisor) do
    supervisor
    |> DynamicSupervisor.which_children()
    |> Enum.each(fn {_id, pid, _type, _modules} ->
      if Process.alive?(pid) do
        DynamicSupervisor.terminate_child(supervisor, pid)
      end
    end)
  end
end
