defmodule Fleetlm.Chat.InboxSupervisor do
  @moduledoc """
  Dynamic supervisor for per-participant inbox processes.
  """

  use DynamicSupervisor

  alias Fleetlm.Chat.InboxServer

  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @spec ensure_started(String.t()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(participant_id) do
    case Registry.lookup(Fleetlm.Chat.InboxRegistry, participant_id) do
      [{pid, _}] ->
        case ensure_ready(pid) do
          {:ok, _} ->
            {:ok, pid}

          {:error, _reason} ->
            DynamicSupervisor.terminate_child(__MODULE__, pid)
            ensure_started(participant_id)
        end

      [] ->
        case DynamicSupervisor.start_child(__MODULE__, {InboxServer, participant_id}) do
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
