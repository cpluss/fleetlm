defmodule Fleetlm.CircuitBreaker do
  @moduledoc """
  Simple circuit breaker implementation for database and external service calls.

  Prevents cascading failures by tracking error rates and temporarily disabling
  operations when a service is unhealthy.
  """

  use GenServer
  require Logger

  defstruct [
    :name,
    :failure_threshold,
    :recovery_time,
    :timeout,
    state: :closed,
    failure_count: 0,
    last_failure_time: nil,
    call_count: 0,
    success_count: 0
  ]

  # Circuit breaker states:
  # :closed - normal operation, requests pass through
  # :open - failing fast, requests rejected immediately
  # :half_open - testing if service recovered, limited requests allowed

  ## Client API

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Execute a function with circuit breaker protection"
  def call(circuit_breaker, fun, timeout \\ 5000) when is_function(fun, 0) do
    case GenServer.call(circuit_breaker, :call_status, timeout) do
      :allow ->
        try do
          result = fun.()
          GenServer.cast(circuit_breaker, :success)
          {:ok, result}
        rescue
          error ->
            GenServer.cast(circuit_breaker, :failure)
            {:error, error}
        catch
          :exit, reason ->
            GenServer.cast(circuit_breaker, :failure)
            {:error, {:exit, reason}}
        end

      :reject ->
        {:error, :circuit_breaker_open}
    end
  end

  @doc "Get circuit breaker status"
  def status(circuit_breaker) do
    GenServer.call(circuit_breaker, :status)
  end

  ## GenServer Callbacks

  @impl true
  def init(opts) do
    state = %__MODULE__{
      name: Keyword.fetch!(opts, :name),
      failure_threshold: Keyword.get(opts, :failure_threshold, 5),
      recovery_time: Keyword.get(opts, :recovery_time, 60_000), # 1 minute
      timeout: Keyword.get(opts, :timeout, 5_000)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:call_status, _from, state) do
    case evaluate_state(state) do
      {:allow, new_state} ->
        {:reply, :allow, %{new_state | call_count: new_state.call_count + 1}}

      {:reject, new_state} ->
        {:reply, :reject, new_state}
    end
  end

  def handle_call(:status, _from, state) do
    status = %{
      name: state.name,
      state: state.state,
      failure_count: state.failure_count,
      call_count: state.call_count,
      success_count: state.success_count,
      success_rate: calculate_success_rate(state)
    }

    {:reply, status, state}
  end

  @impl true
  def handle_cast(:success, state) do
    new_state = %{state |
      success_count: state.success_count + 1,
      failure_count: 0,
      state: :closed
    }

    {:noreply, new_state}
  end

  def handle_cast(:failure, state) do
    failure_count = state.failure_count + 1

    new_state = %{state |
      failure_count: failure_count,
      last_failure_time: System.monotonic_time(:millisecond)
    }

    new_state = if failure_count >= state.failure_threshold do
      Logger.warning("Circuit breaker #{state.name} opened after #{failure_count} failures")
      %{new_state | state: :open}
    else
      new_state
    end

    {:noreply, new_state}
  end

  ## Private Functions

  defp evaluate_state(%{state: :closed} = state) do
    {:allow, state}
  end

  defp evaluate_state(%{state: :open} = state) do
    if should_attempt_reset?(state) do
      Logger.info("Circuit breaker #{state.name} entering half-open state")
      {:allow, %{state | state: :half_open}}
    else
      {:reject, state}
    end
  end

  defp evaluate_state(%{state: :half_open} = state) do
    {:allow, state}
  end

  defp should_attempt_reset?(state) do
    case state.last_failure_time do
      nil -> true
      last_failure ->
        elapsed = System.monotonic_time(:millisecond) - last_failure
        elapsed >= state.recovery_time
    end
  end

  defp calculate_success_rate(state) do
    if state.call_count > 0 do
      (state.success_count / state.call_count * 100) |> Float.round(2)
    else
      0.0
    end
  end
end