defmodule Fleetlm.Webhook.WorkerSupervisor do
  @moduledoc """
  Dynamic supervisor that owns one webhook worker per session. The Raft FSM
  emits `:ensure_worker` commands which route here.
  """

  use DynamicSupervisor

  alias Fleetlm.Webhook.Worker

  def start_link(arg) do
    DynamicSupervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @spec ensure_catch_up(String.t(), map()) :: :ok
  def ensure_catch_up(session_id, params) do
    with {:ok, pid} <- ensure_started(session_id) do
      :gen_statem.cast(pid, {:catch_up, params})
    end
  end

  @spec trigger_compaction(String.t(), map()) :: :ok
  def trigger_compaction(session_id, params) do
    with {:ok, pid} <- ensure_started(session_id) do
      :gen_statem.cast(pid, {:compact, params})
    end
  end

  @spec stop_all() :: :ok
  def stop_all do
    DynamicSupervisor.which_children(__MODULE__)
    |> Enum.each(fn {_, pid, _, _} ->
      DynamicSupervisor.terminate_child(__MODULE__, pid)
    end)

    :ok
  end

  defp ensure_started(session_id) do
    case Registry.lookup(Fleetlm.Webhook.WorkerRegistry, session_id) do
      [{pid, _}] when is_pid(pid) ->
        {:ok, pid}

      [] ->
        case DynamicSupervisor.start_child(__MODULE__, {Worker, session_id}) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          other -> other
        end
    end
  end
end
