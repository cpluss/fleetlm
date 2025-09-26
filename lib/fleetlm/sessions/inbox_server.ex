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

  @spec start_link(String.t()) :: GenServer.on_start()
  def start_link(participant_id) when is_binary(participant_id) do
    GenServer.start_link(__MODULE__, participant_id, name: via(participant_id))
  end

  def via(participant_id), do: {:via, Registry, {Fleetlm.Sessions.InboxRegistry, participant_id}}

  @spec enqueue_update(String.t(), Sessions.ChatSession.t(), map()) :: :ok
  def enqueue_update(participant_id, session, message) do
    GenServer.cast(via(participant_id), {:updated, session, message})
  end

  @impl true
  def init(participant_id) do
    snapshot = load_snapshot(participant_id)
    {:ok, %{participant_id: participant_id, snapshot: snapshot}}
  end

  @impl true
  def handle_cast({:updated, _session, _message}, state) do
    snapshot = load_snapshot(state.participant_id)
    broadcast_snapshot(state.participant_id, snapshot)
    {:noreply, %{state | snapshot: snapshot}}
  end

  defp load_snapshot(participant_id) do
    case Cache.fetch_inbox_snapshot(participant_id) do
      {:ok, snapshot} -> snapshot
      :miss -> refresh_snapshot(participant_id)
      {:error, _} -> refresh_snapshot(participant_id)
    end
  end

  defp refresh_snapshot(participant_id) do
    sessions = Sessions.list_sessions_for_participant(participant_id)

    snapshot =
      Enum.map(sessions, fn session ->
        %{
          "session_id" => session.id,
          "kind" => session.kind,
          "status" => session.status,
          "last_message_id" => session.last_message_id,
          "last_message_at" => encode_datetime(session.last_message_at),
          "agent_id" => session.agent_id,
          "initiator_id" => session.initiator_id,
          "peer_id" => session.peer_id
        }
      end)

    Cache.put_inbox_snapshot(participant_id, snapshot)
    snapshot
  end

  defp broadcast_snapshot(participant_id, snapshot) do
    Phoenix.PubSub.broadcast(@pubsub, "inbox:" <> participant_id, {:inbox_snapshot, snapshot})
  end

  defp encode_datetime(nil), do: nil
  defp encode_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp encode_datetime(%NaiveDateTime{} = naive), do: NaiveDateTime.to_iso8601(naive)
end
