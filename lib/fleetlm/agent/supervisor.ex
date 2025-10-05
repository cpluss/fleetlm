defmodule Fleetlm.Agent.Supervisor do
  @moduledoc """
  Supervisor for the agent webhook delivery system.

  Boots the shared task supervisor and dispatch engine that manage agent
  webhook delivery.
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      # Agent config cache (ETS) - must start before workers
      Fleetlm.Agent.Cache,
      # HTTP client pool for agent webhooks
      {Finch,
       name: Fleetlm.Agent.HTTP,
       pools: %{
         :default => [size: 100, count: 1]
       }},
      {Task.Supervisor, name: Fleetlm.Agent.Engine.TaskSupervisor},
      Fleetlm.Agent.Engine
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
