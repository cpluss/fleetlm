defmodule Fleetlm.Runtime.InboxSupervisor do
  @moduledoc """
  DynamicSupervisor for `InboxServer` processes.

  Each user gets an event-driven GenServer that tracks their session snapshots
  via PubSub. This supervisor manages the lifecycle of inbox processes.

  Note: Agents do NOT have inboxes - they communicate via webhooks only.
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
  def ensure_started(user_id) when is_binary(user_id) do
    case Registry.lookup(Fleetlm.Runtime.InboxRegistry, user_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        child = {Fleetlm.Runtime.InboxServer, user_id}
        DynamicSupervisor.start_child(__MODULE__, child)
    end
  end

  @spec has_started?(String.t()) :: {:ok, pid()} | {:error, :not_started}
  def has_started?(user_id) when is_binary(user_id) do
    case Registry.lookup(Fleetlm.Runtime.InboxRegistry, user_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        {:error, :not_started}
    end
  end

  @spec active_count() :: non_neg_integer()
  def active_count do
    case Process.whereis(Fleetlm.Runtime.InboxRegistry) do
      nil -> 0
      _ -> Registry.count(Fleetlm.Runtime.InboxRegistry)
    end
  end
end
