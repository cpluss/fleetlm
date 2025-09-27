defmodule Fleetlm.Sessions.SessionSupervisor do
  @moduledoc """
  DynamicSupervisor responsible for starting `SessionServer` processes.

  The supervisor exposes `ensure_started/1`, mirroring the previous chat
  implementation, so higher-level code can guarantee a runtime process exists
  before sending casts/calls.
  """

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
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        child = {Fleetlm.Sessions.SessionServer, session_id}
        DynamicSupervisor.start_child(__MODULE__, child)
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
