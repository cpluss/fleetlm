defmodule Fleetlm.Sessions.InboxServer do
  @moduledoc """
  Per-participant server that materialises inbox snapshots.

  The server reacts to updates from `SessionServer`, refreshes the participant's
  session list, caches it in Cachex, and broadcasts `"inbox:"` PubSub updates.
  This keeps inbox rendering snappy without repeatedly hitting the database.
  """

  use GenServer, restart: :transient

  alias Fleetlm.{Repo, Sessions}
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
    maybe_put_owner(state.sandbox_owner)
    snapshot = refresh_snapshot(state.participant_id)
    broadcast_snapshot(state.participant_id, snapshot)
    {:noreply, %{state | snapshot: snapshot}}
  end

  @impl true
  def handle_call(:flush, _from, state) do
    maybe_put_owner(state.sandbox_owner)
    snapshot = refresh_snapshot(state.participant_id)
    broadcast_snapshot(state.participant_id, snapshot)
    {:reply, :ok, %{state | snapshot: snapshot}}
  end

  defp load_snapshot(participant_id) do
    case Cache.fetch_inbox_snapshot(participant_id) do
      {:ok, snapshot} -> snapshot
      _ -> []
    end
  end

  defp refresh_snapshot(participant_id) do
    # Use a single database transaction to avoid connection leaks
    Repo.transaction(fn ->
      sessions = Sessions.list_sessions_for_participant(participant_id, limit: @snapshot_limit)

      Enum.map(sessions, fn session ->
        unread_count = Sessions.unread_count(session, participant_id)

        %{
          "session_id" => session.id,
          "kind" => session.kind,
          "status" => session.status,
          "last_message_id" => session.last_message_id,
          "last_message_at" => encode_datetime(session.last_message_at),
          "agent_id" => session.agent_id,
          "initiator_id" => session.initiator_id,
          "peer_id" => session.peer_id,
          "initiator_last_read_id" => session.initiator_last_read_id,
          "initiator_last_read_at" => encode_datetime(session.initiator_last_read_at),
          "peer_last_read_id" => session.peer_last_read_id,
          "peer_last_read_at" => encode_datetime(session.peer_last_read_at),
          "unread_count" => unread_count
        }
      end)
    end)
    |> case do
      {:ok, snapshot} ->
        Cache.put_inbox_snapshot(participant_id, snapshot)
        snapshot
      {:error, _reason} ->
        # Return cached snapshot on transaction failure
        case Cache.fetch_inbox_snapshot(participant_id) do
          {:ok, snapshot} -> snapshot
          _ -> []
        end
    end
  end

  defp broadcast_snapshot(participant_id, snapshot) do
    Phoenix.PubSub.broadcast(@pubsub, "inbox:" <> participant_id, {:inbox_snapshot, snapshot})
  end

  defp encode_datetime(nil), do: nil
  defp encode_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp encode_datetime(%NaiveDateTime{} = naive), do: NaiveDateTime.to_iso8601(naive)

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
