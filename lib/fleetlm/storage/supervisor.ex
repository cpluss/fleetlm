defmodule Fleetlm.Storage.Supervisor do
  @moduledoc """
  Root supervisor for storage slots.

  Provides a canonical owner for the Registry, task supervisor, and
  dynamic slot log servers so tests and runtime code can share the
  same supervision pattern as other sharded components (sessions,
  inboxes, etc.). Slot log servers are started lazily via
  `ensure_started/1` but the dynamic supervisor is always available.
  """

  use Supervisor

  alias Fleetlm.Storage.SlotLogServer

  @registry Fleetlm.Storage.Registry
  @task_supervisor Fleetlm.Storage.SlotLogTaskSupervisor
  @slot_supervisor Fleetlm.Storage.SlotSupervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      {Registry, keys: :unique, name: @registry},
      {Task.Supervisor, name: @task_supervisor},
      {Fleetlm.Storage.SlotSupervisor, []}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc """
  Ensure a slot log server is running.
  """
  @spec ensure_started(non_neg_integer()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(slot) when is_integer(slot) and slot >= 0 do
    case Registry.lookup(@registry, slot) do
      [{pid, _}] when is_pid(pid) ->
        {:ok, pid}

      [] ->
        start_slot(slot)
    end
  end

  @doc """
  Flush a slot log server if it exists.
  """
  @spec flush_slot(non_neg_integer()) :: :ok | :already_clean | {:error, term()}
  def flush_slot(slot) do
    case Registry.lookup(@registry, slot) do
      [{_pid, _}] ->
        case SlotLogServer.flush_now(slot) do
          :ok -> :ok
          :already_clean -> :ok
          {:error, _} = error -> error
        end

      [] ->
        :ok
    end
  end

  @doc """
  Return a list of active slot ids.
  """
  @spec active_slots() :: [non_neg_integer()]
  def active_slots do
    if Process.whereis(@registry) do
      Registry.select(@registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
      |> Enum.uniq()
    else
      []
    end
  end

  @doc """
  Stop a slot log server if it's currently running.
  """
  @spec stop_slot(non_neg_integer()) :: :ok
  def stop_slot(slot) do
    case Registry.lookup(@registry, slot) do
      [{pid, _}] when is_pid(pid) ->
        _ = flush_slot(slot)

        case DynamicSupervisor.terminate_child(@slot_supervisor, pid) do
          :ok -> :ok
          {:error, :not_found} -> :ok
          {:error, _} = error -> error
        end

      [] ->
        :ok
    end
  end

  defp start_slot(slot) do
    child =
      {SlotLogServer, {slot, task_supervisor: @task_supervisor, registry: @registry}}

    case DynamicSupervisor.start_child(@slot_supervisor, child) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, _} = error -> error
    end
  end
end

defmodule Fleetlm.Storage.SlotSupervisor do
  @moduledoc false

  use DynamicSupervisor

  def start_link(_opts) do
    DynamicSupervisor.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
