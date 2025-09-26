defmodule Fleetlm.Sessions.SessionSupervisor do
  @moduledoc false

  use DynamicSupervisor

  @registry Fleetlm.Sessions.SessionRegistry

  def start_link(arg) do
    DynamicSupervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @spec ensure_started(String.t()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(session_id) when is_binary(session_id) do
    case Registry.lookup(@registry, session_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> DynamicSupervisor.start_child(__MODULE__, {Fleetlm.Sessions.SessionServer, session_id})
    end
  end

  @spec active_count() :: non_neg_integer()
  def active_count do
    case Process.whereis(@registry) do
      nil -> 0
      _ -> Registry.count(@registry)
    end
  end
end
