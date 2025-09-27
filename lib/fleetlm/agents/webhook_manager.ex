defmodule Fleetlm.Agents.WebhookManager do
  @moduledoc """
  Pooled webhook delivery system for agent endpoints.

  Features:
  - Connection pooling with :req for HTTP efficiency
  - Batch endpoint loading to reduce database hits
  - Circuit breaker pattern for failed endpoints
  - Dedicated worker pool using :poolboy
  - Telemetry and delivery logging

  This replaces the simple Task.Supervisor approach with a more robust,
  scalable webhook delivery system.
  """

  use GenServer
  require Logger

  alias Fleetlm.Agents
  alias Fleetlm.Agents.{AgentEndpoint, EndpointCache}
  alias Fleetlm.Repo

  @pool_name :webhook_delivery_pool

  ## Public API

  @doc """
  Start the webhook manager.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Deliver webhook for a single agent session message.
  Returns immediately, actual delivery happens asynchronously.
  """
  @spec deliver_async(String.t(), map(), map()) :: :ok
  def deliver_async(agent_id, session, message) do
    :poolboy.transaction(@pool_name, fn worker ->
      GenServer.cast(worker, {:deliver, agent_id, session, message})
    end)
  end

  @doc """
  Batch deliver webhooks for multiple agents.
  Optimized for concurrent message sending scenarios.
  """
  @spec deliver_batch([{String.t(), map(), map()}]) :: :ok
  def deliver_batch(deliveries) when is_list(deliveries) do
    # Group by agent_id for efficient endpoint loading
    grouped = Enum.group_by(deliveries, fn {agent_id, _session, _message} -> agent_id end)

    # Pre-load all agent endpoints in a single query
    agent_ids = Map.keys(grouped)
    endpoint_map = load_endpoints_batch(agent_ids)

    # Distribute work across pool
    Enum.each(grouped, fn {agent_id, deliveries_for_agent} ->
      endpoint = Map.get(endpoint_map, agent_id)

      :poolboy.transaction(@pool_name, fn worker ->
        GenServer.cast(worker, {:deliver_batch, endpoint, deliveries_for_agent})
      end)
    end)

    :ok
  end

  @doc """
  Get webhook delivery statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  ## GenServer Implementation

  @impl true
  def init(opts) do
    pool_size = Keyword.get(opts, :pool_size, 10)

    # Start the worker pool
    pool_spec = [
      name: {:local, @pool_name},
      worker_module: Fleetlm.Agents.WebhookWorker,
      size: pool_size,
      max_overflow: div(pool_size, 2)
    ]

    case :poolboy.start_link(pool_spec) do
      {:ok, _pid} ->
        Logger.info("WebhookManager: Started with pool size #{pool_size}")

        # Initialize stats
        state = %{
          stats: %{
            deliveries_attempted: 0,
            deliveries_succeeded: 0,
            deliveries_failed: 0,
            endpoints_cached: 0
          }
        }

        {:ok, state}

      error ->
        Logger.error("WebhookManager: Failed to start pool: #{inspect(error)}")
        {:stop, error}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply, state.stats, state}
  end

  @impl true
  def handle_info({:delivery_result, result}, state) do
    # Update stats based on delivery results
    updated_stats =
      case result do
        :success ->
          %{state.stats | deliveries_succeeded: state.stats.deliveries_succeeded + 1}

        :failure ->
          %{state.stats | deliveries_failed: state.stats.deliveries_failed + 1}
      end

    {:noreply, %{state | stats: updated_stats}}
  end

  ## Private Functions

  defp load_endpoints_batch(agent_ids) do
    # Use batch loading with cache
    case EndpointCache.get_statuses(agent_ids) do
      statuses when is_map(statuses) ->
        # Only load full endpoints for enabled agents
        enabled_agent_ids =
          statuses
          |> Enum.filter(fn {_id, status} -> status == "enabled" end)
          |> Enum.map(fn {id, _status} -> id end)

        if length(enabled_agent_ids) > 0 do
          load_full_endpoints(enabled_agent_ids)
        else
          %{}
        end

      _ ->
        # Fallback to individual loading
        agent_ids
        |> Enum.map(fn agent_id -> {agent_id, Agents.get_endpoint(agent_id)} end)
        |> Enum.filter(fn {_id, endpoint} -> endpoint && endpoint.status == "enabled" end)
        |> Map.new()
    end
  end

  defp load_full_endpoints(agent_ids) do
    import Ecto.Query

    AgentEndpoint
    |> where([e], e.agent_id in ^agent_ids and e.status == "enabled")
    |> Repo.all()
    |> Enum.map(fn endpoint -> {endpoint.agent_id, endpoint} end)
    |> Map.new()
  end
end
