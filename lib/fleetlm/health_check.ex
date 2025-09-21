defmodule Fleetlm.HealthCheck do
  @moduledoc """
  Health check utilities for monitoring system components.
  """

  alias Fleetlm.{Cache, CircuitBreaker, Repo}

  @doc "Perform comprehensive health check"
  def check_all do
    checks = [
      database: check_database(),
      cache: check_cache(),
      circuit_breakers: check_circuit_breakers(),
      process_count: check_process_count()
    ]

    overall_status = if Enum.all?(checks, fn {_name, %{status: status}} -> status == :ok end) do
      :healthy
    else
      :unhealthy
    end

    %{
      status: overall_status,
      timestamp: DateTime.utc_now(),
      checks: Map.new(checks)
    }
  end

  @doc "Check database connectivity"
  def check_database do
    try do
      case Ecto.Adapters.SQL.query(Repo, "SELECT 1", []) do
        {:ok, _} ->
          %{status: :ok, message: "Database connection healthy"}
        {:error, reason} ->
          %{status: :error, message: "Database error: #{inspect(reason)}"}
      end
    rescue
      error ->
        %{status: :error, message: "Database exception: #{inspect(error)}"}
    end
  end

  @doc "Check cache system"
  def check_cache do
    try do
      test_key = "health_check_#{:rand.uniform(1000)}"

      case Cache.cache_thread_meta(test_key, %{test: true}) do
        :ok ->
          case Cache.get_thread_meta(test_key) do
            %{test: true} ->
              Cache.invalidate_thread_meta(test_key)
              %{status: :ok, message: "Cache system healthy"}
            _ ->
              %{status: :warning, message: "Cache read/write inconsistent"}
          end
        _ ->
          %{status: :error, message: "Cache write failed"}
      end
    rescue
      error ->
        %{status: :error, message: "Cache exception: #{inspect(error)}"}
    end
  end

  @doc "Check circuit breaker status"
  def check_circuit_breakers do
    breakers = [:db_circuit_breaker, :cache_circuit_breaker]

    statuses = Enum.map(breakers, fn name ->
      try do
        status = CircuitBreaker.status(name)
        {name, %{
          status: if(status.state == :closed, do: :ok, else: :warning),
          state: status.state,
          success_rate: status.success_rate,
          failure_count: status.failure_count
        }}
      rescue
        _ ->
          {name, %{status: :error, message: "Circuit breaker unreachable"}}
      end
    end)

    overall = if Enum.all?(statuses, fn {_name, %{status: status}} -> status in [:ok, :warning] end) do
      :ok
    else
      :error
    end

    %{
      status: overall,
      circuit_breakers: Map.new(statuses)
    }
  end

  @doc "Check system process counts"
  def check_process_count do
    process_count = length(Process.list())
    thread_servers = Registry.count(Fleetlm.Chat.ThreadRegistry)

    %{
      status: :ok,
      total_processes: process_count,
      thread_servers: thread_servers,
      memory_usage: get_memory_info()
    }
  end

  @doc "Get memory usage statistics"
  def get_memory_info do
    memory = :erlang.memory()

    %{
      total_mb: div(memory[:total], 1024 * 1024),
      processes_mb: div(memory[:processes], 1024 * 1024),
      atom_mb: div(memory[:atom], 1024 * 1024),
      ets_mb: div(memory[:ets], 1024 * 1024)
    }
  end

  @doc "Simple health check for load balancers"
  def check_basic do
    case check_database() do
      %{status: :ok} -> :ok
      _ -> :error
    end
  end
end