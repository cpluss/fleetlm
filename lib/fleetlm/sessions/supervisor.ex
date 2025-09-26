defmodule Fleetlm.Sessions.Supervisor do
  @moduledoc """
  Root supervisor for the session runtime tree.

  Starts Cachex caches, registries, and the dynamic supervisors that manage
  session/inbox servers. Swapping `Fleetlm.Chat.Supervisor` for this module in
  `Fleetlm.Application` switches the runtime to the new architecture while
  preserving a similar supervision layout.
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
