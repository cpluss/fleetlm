defmodule Fleetlm.Chat.ConversationSupervisor do
  @moduledoc """
  Dynamic supervisor for conversation processes.
  """

  use DynamicSupervisor

  alias Fleetlm.Chat.ConversationServer

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @spec ensure_started(String.t()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(dm_key) do
    case Registry.lookup(Fleetlm.Chat.ConversationRegistry, dm_key) do
      [{pid, _}] -> {:ok, pid}
      [] -> DynamicSupervisor.start_child(__MODULE__, {ConversationServer, dm_key})
    end
  end

  @impl true
  def init(_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
