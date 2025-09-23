defmodule Fleetlm.Chat.InboxSupervisor do
  @moduledoc false

  use DynamicSupervisor

  alias Fleetlm.Chat.InboxServer

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(arg) do
    DynamicSupervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @spec ensure_started(String.t()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(participant_id) do
    case Registry.lookup(Fleetlm.Chat.InboxRegistry, participant_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        spec = {InboxServer, participant_id}

        case DynamicSupervisor.start_child(__MODULE__, spec) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          other -> other
        end
    end
  end

  @impl true
  def init(_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
