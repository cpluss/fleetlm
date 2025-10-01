defmodule Fleetlm.Agent.Dispatcher do
  @moduledoc """
  Routes webhook dispatch requests to pooled WebhookWorker processes.

  Keeps things simple: just delegates to poolboy, which manages
  the worker pool and load distribution.
  """

  @pool_name :agent_webhook_pool

  @doc """
  Dispatch webhook asynchronously via poolboy.
  Returns immediately - worker handles all the work.
  """
  @spec dispatch_async(String.t(), String.t()) :: :ok
  def dispatch_async(session_id, agent_id) do
    if Application.get_env(:fleetlm, :disable_agent_webhooks, false) do
      :ok
    else
      :poolboy.transaction(@pool_name, fn worker ->
        GenServer.cast(worker, {:dispatch, session_id, agent_id})
      end)

      :ok
    end
  end
end
