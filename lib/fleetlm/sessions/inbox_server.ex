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
    GenServer.start_link(__MODULE__, participant_id, name: via(participant_id))
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
  def init(participant_id) do
    # Load snapshot lazily to avoid database access during init
    {:ok, %{participant_id: participant_id, snapshot: nil}}
  end

  @impl true
  def handle_cast({:updated, _session, _message}, state) do
    # Invalidate cache to force fresh snapshot on next request
    Cache.delete_inbox_snapshot(state.participant_id)
    snapshot = Sessions.get_inbox_snapshot(state.participant_id, limit: @snapshot_limit)
    broadcast_snapshot(state.participant_id, snapshot)

    {:noreply, %{state | snapshot: snapshot}}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    # Invalidate cache and get fresh snapshot
    Cache.delete_inbox_snapshot(state.participant_id)
    snapshot = Sessions.get_inbox_snapshot(state.participant_id, limit: @snapshot_limit)
    broadcast_snapshot(state.participant_id, snapshot)
    {:reply, :ok, %{state | snapshot: snapshot}}
  end


  defp broadcast_snapshot(participant_id, snapshot) do
    Phoenix.PubSub.broadcast(@pubsub, "inbox:" <> participant_id, {:inbox_snapshot, snapshot})
  end


end
