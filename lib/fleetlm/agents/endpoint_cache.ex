defmodule Fleetlm.Agents.EndpointCache do
  @moduledoc """
  High-performance caching layer for agent endpoint status lookups.

  This module provides:
  - Cachex-based caching with 15s TTL for hot paths
  - Cache warming on agent endpoint changes
  - Automatic fallback to database on cache misses
  - Batch loading support for concurrent operations

  Used by the dispatcher to eliminate database roundtrips on message sending.
  """

  use GenServer
  require Logger
  alias Fleetlm.Agents

  @cache_name :agent_endpoint_status_cache
  @default_ttl :timer.seconds(15)

  ## Public API

  @doc """
  Start the endpoint cache GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get agent endpoint status with caching.
  Returns status string or nil if agent doesn't exist or is disabled.
  """
  @spec get_status(String.t()) :: String.t() | nil
  def get_status(agent_id) when is_binary(agent_id) do
    case Cachex.get(@cache_name, agent_id) do
      {:ok, nil} ->
        # Cache miss - load from database and cache result
        load_and_cache_status(agent_id)

      {:ok, status} ->
        # Cache hit
        status

      {:error, _reason} ->
        # Cache error - fallback to database
        Logger.warning("EndpointCache: Cache error for agent #{agent_id}, falling back to database")
        Agents.get_endpoint_status(agent_id)
    end
  end

  @doc """
  Batch load agent endpoint statuses with caching.
  Returns map of agent_id -> status for efficient concurrent operations.
  """
  @spec get_statuses([String.t()]) :: %{String.t() => String.t() | nil}
  def get_statuses(agent_ids) when is_list(agent_ids) do
    {cached, missing} = get_cached_statuses(agent_ids)

    if length(missing) > 0 do
      fresh_statuses = load_and_cache_statuses(missing)
      Map.merge(cached, fresh_statuses)
    else
      cached
    end
  end

  @doc """
  Warm the cache with a specific agent's endpoint status.
  Used when agent endpoints are created or updated.
  """
  @spec warm_cache(String.t(), String.t() | nil) :: :ok
  def warm_cache(agent_id, status) when is_binary(agent_id) do
    Cachex.put(@cache_name, agent_id, status, ttl: @default_ttl)
    :ok
  end

  @doc """
  Invalidate cache entry for a specific agent.
  Used when agent endpoints are deleted or disabled.
  """
  @spec invalidate(String.t()) :: :ok
  def invalidate(agent_id) when is_binary(agent_id) do
    Cachex.del(@cache_name, agent_id)
    :ok
  end

  @doc """
  Clear the entire cache.
  Used for testing or emergency cache flushing.
  """
  @spec clear() :: :ok
  def clear do
    Cachex.clear(@cache_name)
    :ok
  end

  @doc """
  Get cache statistics for monitoring.
  """
  @spec stats() :: map()
  def stats do
    case Cachex.stats(@cache_name) do
      {:ok, stats} -> stats
      {:error, _} -> %{}
    end
  end

  ## GenServer Implementation

  @impl true
  def init(_opts) do
    # Start the cache with basic configuration
    case Cachex.start_link(@cache_name, [
      limit: 10000
    ]) do
      {:ok, _pid} ->
        Logger.info("EndpointCache: Started with 15s TTL and LRU eviction")
        {:ok, %{}}

      {:error, {:already_started, _pid}} ->
        Logger.info("EndpointCache: Cache already started")
        {:ok, %{}}

      error ->
        Logger.error("EndpointCache: Failed to start cache: #{inspect(error)}")
        {:stop, error}
    end
  end

  ## Private Functions

  defp load_and_cache_status(agent_id) do
    case Agents.get_endpoint_status(agent_id) do
      nil ->
        # Cache the nil result to avoid repeated database hits for non-existent agents
        Cachex.put(@cache_name, agent_id, nil, ttl: @default_ttl)
        nil

      status ->
        # Cache the status
        Cachex.put(@cache_name, agent_id, status, ttl: @default_ttl)
        status
    end
  end

  defp get_cached_statuses(agent_ids) do
    Enum.reduce(agent_ids, {%{}, []}, fn agent_id, {cached_acc, missing_acc} ->
      case Cachex.get(@cache_name, agent_id) do
        {:ok, nil} ->
          {cached_acc, [agent_id | missing_acc]}
        {:ok, status} ->
          {Map.put(cached_acc, agent_id, status), missing_acc}
        {:error, _} ->
          {cached_acc, [agent_id | missing_acc]}
      end
    end)
  end

  defp load_and_cache_statuses(agent_ids) do
    # Batch load from database
    statuses = load_statuses_from_db(agent_ids)

    # Cache all results
    Enum.each(statuses, fn {agent_id, status} ->
      Cachex.put(@cache_name, agent_id, status, ttl: @default_ttl)
    end)

    statuses
  end

  defp load_statuses_from_db(agent_ids) do
    # Use optimized batch query
    Agents.get_endpoint_statuses(agent_ids)
  end
end