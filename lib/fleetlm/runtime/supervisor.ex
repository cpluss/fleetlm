defmodule Fleetlm.Runtime.Supervisor do
  @moduledoc """
  Root supervisor for the session runtime tree.

  Starts Cachex caches, registries, and the dynamic supervisors that manage
  session/inbox servers. It also hosts the sharding control plane, which keeps
  the consistent hash ring and slot owners in sync so the gateway sees a
  cluster-wide load balancer instead of node-local state.
  """

  use Supervisor

  alias Fleetlm.Runtime.CacheSupervisor
  alias Fleetlm.Runtime.SessionSupervisor
  alias Fleetlm.Runtime.InboxSupervisor

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      CacheSupervisor,
      {Registry, keys: :unique, name: Fleetlm.Runtime.Sharding.LocalRegistry},
      Fleetlm.Runtime.Sharding.Supervisor,
      Fleetlm.Runtime.Sharding.Manager,
      {Registry, keys: :unique, name: Fleetlm.Runtime.SessionRegistry},
      {Registry, keys: :unique, name: Fleetlm.Runtime.InboxRegistry},
      {SessionSupervisor, []},
      {InboxSupervisor, []}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
