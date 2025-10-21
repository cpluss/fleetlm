defmodule Fleetlm.Storage.Supervisor do
  @moduledoc """
  Supervisor for storage infrastructure.

  Starts:
  - Agent cache (ETS)
  - HTTP client pool for webhook calls
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      # Agent config cache (ETS) - must start before webhook workers
      Fleetlm.Storage.AgentCache,

      # HTTP client pool for webhooks (both agent and compaction)
      {Finch,
       name: Fleetlm.Webhook.HTTP,
       pools: %{
         :default => [size: 100, count: 1]
       }}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
