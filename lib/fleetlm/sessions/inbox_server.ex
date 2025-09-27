defmodule Fleetlm.Sessions.InboxServer do
  @moduledoc """
  Per-participant server that materialises inbox snapshots.

  The server reacts to updates from `SessionServer`, refreshes the participant's
  session list, caches it in Cachex, and broadcasts `"inbox:"` PubSub updates.
  This keeps inbox rendering snappy without repeatedly hitting the database.
  """

  use GenServer, restart: :transient

  alias Fleetlm.Sessions
  alias Fleetlm.Sessions.Cache

  @pubsub Fleetlm.PubSub
  @snapshot_limit 200

  @spec start_link(String.t()) :: GenServer.on_start()
  def start_link(participant_id) when is_binary(participant_id) do
    GenServer.start_link(__MODULE__, {participant_id, nil}, name: via(participant_id))
  end

  def start_link({participant_id, opts}) when is_binary(participant_id) and is_list(opts) do
    owner = Keyword.get(opts, :sandbox_owner)
    GenServer.start_link(__MODULE__, {participant_id, owner}, name: via(participant_id))
  end

  def via(participant_id), do: {:via, Registry, {Fleetlm.Sessions.InboxRegistry, participant_id}}

  @spec flush(String.t()) :: :ok
  def flush(participant_id) when is_binary(participant_id) do
    GenServer.call(via(participant_id), :flush)
  end

  @spec enqueue_update(String.t(), Sessions.ChatSession.t(), map()) :: :ok
  def enqueue_update(participant_id, session, message) do
    GenServer.cast(via(participant_id), {:updated, session, message})
  end

  @impl true
  def init({participant_id, owner}) do
    maybe_put_owner(owner)
    maybe_allow_sandbox(owner)
    snapshot = load_snapshot(participant_id)
    {:ok, %{participant_id: participant_id, snapshot: snapshot, sandbox_owner: owner}}
  end

  @impl true
  def handle_cast({:updated, _session, _message}, state) do
    # Move database operations to async task to avoid blocking GenServer
    participant_id = state.participant_id
    sandbox_owner = state.sandbox_owner

    Task.start(fn ->
      maybe_put_owner(sandbox_owner)
      # Invalidate cache to force fresh snapshot on next request
      Cache.delete_inbox_snapshot(participant_id)
      snapshot = Sessions.get_inbox_snapshot(participant_id, limit: @snapshot_limit)
      broadcast_snapshot(participant_id, snapshot)
    end)

    {:noreply, state}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    maybe_put_owner(state.sandbox_owner)
    # Invalidate cache and get fresh snapshot
    Cache.delete_inbox_snapshot(state.participant_id)
    snapshot = Sessions.get_inbox_snapshot(state.participant_id, limit: @snapshot_limit)
    broadcast_snapshot(state.participant_id, snapshot)
    {:reply, :ok, %{state | snapshot: snapshot}}
  end

  defp load_snapshot(participant_id) do
    # Use read-through caching pattern
    Sessions.get_inbox_snapshot(participant_id, limit: @snapshot_limit)
  end

  defp broadcast_snapshot(participant_id, snapshot) do
    Phoenix.PubSub.broadcast(@pubsub, "inbox:" <> participant_id, {:inbox_snapshot, snapshot})
  end

  defp maybe_allow_sandbox(nil), do: :ok

  defp maybe_allow_sandbox(owner) when is_pid(owner) do
    if Code.ensure_loaded?(Ecto.Adapters.SQL.Sandbox) do
      Ecto.Adapters.SQL.Sandbox.allow(Fleetlm.Repo, owner, self())
    else
      :ok
    end
  end

  defp maybe_put_owner(nil), do: :ok
  defp maybe_put_owner(owner) when is_pid(owner), do: Process.put(:sandbox_owner, owner)
end
