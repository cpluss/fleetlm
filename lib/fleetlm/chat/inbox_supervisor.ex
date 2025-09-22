defmodule Fleetlm.Chat.InboxSupervisor do
  @moduledoc """
  Dynamic supervisor for per-participant inbox processes.
  """

  use DynamicSupervisor

  alias Fleetlm.Chat.InboxServer

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @spec ensure_started(String.t()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(participant_id) do
    case Registry.lookup(Fleetlm.Chat.InboxRegistry, participant_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> DynamicSupervisor.start_child(__MODULE__, {InboxServer, participant_id})
    end
  end

  @impl true
  def init(_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
