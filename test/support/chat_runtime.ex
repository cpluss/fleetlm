defmodule Fleetlm.Chat.TestRuntime do
  @moduledoc false

  alias Fleetlm.Chat.Cache

  def reset do
    terminate_children(Fleetlm.Chat.ConversationRegistry, Fleetlm.Chat.ConversationSupervisor)
    _ = Cache.reset()
    :ok
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
