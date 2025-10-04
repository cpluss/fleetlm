defmodule Fleetlm.Agent.Supervisor do
  @moduledoc """
  Supervisor for the agent webhook delivery system.

  Starts a poolboy pool of WebhookWorker processes that handle
  asynchronous HTTP POSTs to agent endpoints.
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    pool_size = Application.get_env(:fleetlm, :agent_webhook_pool_size, 10)

    poolboy_config = [
      name: {:local, :agent_webhook_pool},
      worker_module: Fleetlm.Agent.WebhookWorker,
      size: pool_size,
      max_overflow: div(pool_size, 2)
    ]

    children = [
      # Agent config cache (ETS) - must start before workers
      Fleetlm.Agent.Cache,
      :poolboy.child_spec(:agent_webhook_pool, poolboy_config)
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
