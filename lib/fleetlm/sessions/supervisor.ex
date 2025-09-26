defmodule Fleetlm.Sessions.Supervisor do
  @moduledoc """
  Top-level supervisor for session runtime processes.
  """

  use Supervisor

  alias Fleetlm.Sessions.CacheSupervisor
  alias Fleetlm.Sessions.SessionSupervisor
  alias Fleetlm.Sessions.InboxSupervisor

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      CacheSupervisor,
      {Registry, keys: :unique, name: Fleetlm.Sessions.SessionRegistry},
      {Registry, keys: :unique, name: Fleetlm.Sessions.InboxRegistry},
      {SessionSupervisor, []},
      {InboxSupervisor, []}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
