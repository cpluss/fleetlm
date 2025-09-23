defmodule Fleetlm.Chat.ConversationSupervisor do
  @moduledoc """
  Dynamic supervisor for conversation processes.
  """

  use DynamicSupervisor

  alias Fleetlm.Chat.ConversationServer

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @spec ensure_started(String.t()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(dm_key) do
    case Registry.lookup(Fleetlm.Chat.ConversationRegistry, dm_key) do
      [{pid, _}] ->
        case ensure_ready(pid) do
          {:ok, _pid} ->
            {:ok, pid}

          {:error, _reason} ->
            DynamicSupervisor.terminate_child(__MODULE__, pid)
            ensure_started(dm_key)
        end

      [] ->
        case DynamicSupervisor.start_child(__MODULE__, {ConversationServer, dm_key}) do
          {:ok, pid} -> ensure_ready(pid)
          {:error, {:already_started, pid}} -> ensure_ready(pid)
          other -> other
        end
    end
  end

  @impl true
  def init(_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Return the number of active conversation processes.
  """
  @spec active_count() :: non_neg_integer()
  def active_count do
    case Process.whereis(Fleetlm.Chat.ConversationRegistry) do
      nil -> 0
      _pid -> safe_registry_count(Fleetlm.Chat.ConversationRegistry)
    end
  end

  defp safe_registry_count(registry) do
    try do
      Registry.count(registry)
    catch
      :exit, _ -> 0
    end
  end

  defp ensure_ready(pid, attempts \\ 20)
  defp ensure_ready(_pid, 0), do: {:error, :not_ready}

  defp ensure_ready(pid, attempts) do
    try do
      GenServer.call(pid, :ping)
      {:ok, pid}
    catch
      :exit, {:noproc, _} ->
        Process.sleep(25)
        ensure_ready(pid, attempts - 1)

      :exit, reason ->
        {:error, reason}
    end
  end
end
