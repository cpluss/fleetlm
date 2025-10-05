defmodule Fleetlm.Agent.Cache do
  @moduledoc """
  ETS-based cache for agent configurations to avoid DB lookups on hot path.

  Agents change infrequently (configuration updates), so we cache them
  to eliminate database queries on every webhook dispatch.
  """

  use GenServer
  require Logger

  @table __MODULE__
  @ttl :timer.minutes(5)

  ## Public API

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Get an agent from cache or load from database.
  Returns the same shape as Agent.get/1 but with caching.
  """
  @spec get(String.t()) :: {:ok, Fleetlm.Agent.t()} | {:error, :not_found}
  def get(agent_id) when is_binary(agent_id) do
    case lookup(agent_id) do
      {:ok, agent} ->
        {:ok, agent}

      :miss ->
        case Fleetlm.Agent.get(agent_id) do
          {:ok, agent} = result ->
            put(agent_id, agent)
            result

          {:error, :not_found} = error ->
            error
        end
    end
  end

  @doc """
  Invalidate cached agent (call after updates).
  """
  @spec invalidate(String.t()) :: :ok
  def invalidate(agent_id) when is_binary(agent_id) do
    GenServer.cast(__MODULE__, {:invalidate, agent_id})
  end

  @doc """
  Clear all cached agents.
  """
  @spec clear_all() :: :ok
  def clear_all do
    GenServer.call(__MODULE__, :clear_all)
  end

  ## GenServer Implementation

  @impl true
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    Logger.info("Agent cache initialized")
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call(:clear_all, _from, state) do
    :ets.delete_all_objects(@table)
    Logger.info("Agent cache cleared")
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:invalidate, agent_id}, state) do
    :ets.delete(@table, agent_id)
    Logger.debug("Agent cache invalidated for #{agent_id}")
    {:noreply, state}
  end

  ## Private Helpers

  defp lookup(agent_id) do
    case :ets.lookup(@table, agent_id) do
      [{^agent_id, agent, expires_at}] ->
        if System.monotonic_time(:millisecond) < expires_at do
          {:ok, agent}
        else
          :ets.delete(@table, agent_id)
          :miss
        end

      [] ->
        :miss
    end
  end

  defp put(agent_id, agent) do
    expires_at = System.monotonic_time(:millisecond) + @ttl
    :ets.insert(@table, {agent_id, agent, expires_at})
    :ok
  end
end
