defmodule Fleetlm.Sessions.InboxSupervisor do
  @moduledoc """
  DynamicSupervisor for `InboxServer` processes.

  Each participant that has an inbox subscription gets a lightweight GenServer
  that tracks their session snapshots. This supervisor mirrors the previous
  chat inbox implementation but is scoped to the new session runtime.
  """

  use DynamicSupervisor

  def start_link(arg) do
    DynamicSupervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @spec ensure_started(String.t()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(participant_id) when is_binary(participant_id) do
    case Registry.lookup(Fleetlm.Sessions.InboxRegistry, participant_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        opts = sandbox_opts()
        child = {Fleetlm.Sessions.InboxServer, {participant_id, opts}}
        DynamicSupervisor.start_child(__MODULE__, child)
    end
  end

  @spec active_count() :: non_neg_integer()
  def active_count do
    case Process.whereis(Fleetlm.Sessions.InboxRegistry) do
      nil -> 0
      _ -> Registry.count(Fleetlm.Sessions.InboxRegistry)
    end
  end

  defp sandbox_opts do
    case Process.get(:sandbox_owner) do
      nil -> []
      owner -> [sandbox_owner: owner]
    end
  end
end
