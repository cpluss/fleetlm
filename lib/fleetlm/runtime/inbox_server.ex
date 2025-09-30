defmodule Fleetlm.Runtime.InboxServer do
  @moduledoc """
  Event-driven per-participant inbox server.

  Responsibilities:
  - Subscribe to PubSub for all sessions participant is in
  - Maintain inbox state (last message, unread count per session)
  - Broadcast inbox updates via PubSub when messages arrive
  - NO database queries during message updates (only on init)
  - Inactivity timeout (15 min → shutdown)

  Lifecycle:
  - Started lazily on first inbox join
  - Shuts down after 15 min inactivity
  """

  use GenServer, restart: :transient
  require Logger

  alias FleetLM.Storage.API, as: StorageAPI

  @inactivity_timeout :timer.minutes(15)
  @pubsub Fleetlm.PubSub

  defstruct [
    :participant_id,
    :sessions,
    :inactivity_timer,
    :last_activity
  ]

  @type session_entry :: %{
          session_id: String.t(),
          other_participant_id: String.t(),
          last_message: map() | nil,
          last_message_at: NaiveDateTime.t() | nil
        }

  @type state :: %__MODULE__{
          participant_id: String.t(),
          sessions: %{String.t() => session_entry()},
          inactivity_timer: reference() | nil,
          last_activity: integer()
        }

  # Client API

  @spec start_link(String.t()) :: GenServer.on_start()
  def start_link(participant_id) when is_binary(participant_id) do
    GenServer.start_link(__MODULE__, participant_id, name: via(participant_id))
  end

  @spec get_snapshot(String.t()) :: {:ok, [map()]} | {:error, term()}
  def get_snapshot(participant_id) do
    GenServer.call(via(participant_id), :get_snapshot, :timer.seconds(5))
  end

  # Server callbacks

  @impl true
  def init(participant_id) do
    Process.flag(:trap_exit, true)

    # Load all sessions for this participant (DB query on init only)
    {:ok, sessions_list} = StorageAPI.get_sessions_for_participant(participant_id)

    # Build session state
    sessions =
      sessions_list
      |> Enum.map(fn session ->
        other_participant_id = get_other_participant(session, participant_id)

        # Subscribe to session PubSub
        Phoenix.PubSub.subscribe(@pubsub, "session:#{session.id}")

        # Load last message for this session (DB query on init only)
        last_message = load_last_message(session.id)

        entry = %{
          session_id: session.id,
          other_participant_id: other_participant_id,
          last_message: last_message,
          last_message_at: get_message_timestamp(last_message)
        }

        {session.id, entry}
      end)
      |> Enum.into(%{})

    timer = schedule_inactivity_check()

    Logger.info("InboxServer started for #{participant_id} with #{map_size(sessions)} sessions")

    {:ok,
     %__MODULE__{
       participant_id: participant_id,
       sessions: sessions,
       inactivity_timer: timer,
       last_activity: System.monotonic_time(:millisecond)
     }}
  end

  @impl true
  def handle_call(:get_snapshot, _from, state) do
    snapshot = build_snapshot(state.sessions)
    new_state = reset_inactivity_timer(state)
    {:reply, {:ok, snapshot}, new_state}
  end

  @impl true
  def handle_info({:session_message, payload}, state) do
    session_id = payload["session_id"]

    # Update session entry
    new_sessions =
      case Map.get(state.sessions, session_id) do
        nil ->
          # Session not in our inbox (shouldn't happen if subscriptions are correct)
          Logger.warning("Received message for unknown session #{session_id}")
          state.sessions

        entry ->
          updated_entry = %{
            entry
            | last_message: payload,
              last_message_at: parse_datetime(payload["inserted_at"])
          }

          Map.put(state.sessions, session_id, updated_entry)
      end

    # Broadcast updated snapshot
    broadcast_snapshot(state.participant_id, build_snapshot(new_sessions))

    new_state = reset_inactivity_timer(%{state | sessions: new_sessions})
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:inactivity_check, state) do
    elapsed = System.monotonic_time(:millisecond) - state.last_activity

    if elapsed >= @inactivity_timeout do
      Logger.info("InboxServer #{state.participant_id} inactive for #{elapsed}ms, shutting down")
      {:stop, :normal, state}
    else
      timer = schedule_inactivity_check()
      {:noreply, %{state | inactivity_timer: timer}}
    end
  end

  @impl true
  def terminate(_reason, state) do
    Logger.info("InboxServer terminating for #{state.participant_id}")
    :ok
  end

  # Private helpers

  defp via(participant_id) do
    {:via, Registry, {Fleetlm.Runtime.InboxRegistry, participant_id}}
  end

  defp get_other_participant(session, participant_id) do
    cond do
      session.sender_id == participant_id -> session.recipient_id
      session.recipient_id == participant_id -> session.sender_id
      true -> session.recipient_id
    end
  end

  defp load_last_message(session_id) do
    import Ecto.Query
    alias FleetLM.Storage.Model.Message

    # Query the most recent message directly from DB (only on init)
    result =
      Message
      |> where([m], m.session_id == ^session_id)
      |> order_by([m], desc: m.seq)
      |> limit(1)
      |> Fleetlm.Repo.one()

    format_message(result)
  end

  defp get_message_timestamp(nil), do: nil
  defp get_message_timestamp(message), do: parse_datetime(message["inserted_at"])

  defp format_message(nil), do: nil

  defp format_message(%FleetLM.Storage.Model.Message{} = message) do
    %{
      "id" => message.id,
      "session_id" => message.session_id,
      "seq" => message.seq,
      "sender_id" => message.sender_id,
      "kind" => message.kind,
      "content" => message.content,
      "metadata" => message.metadata,
      "inserted_at" => encode_datetime(message.inserted_at)
    }
  end

  defp build_snapshot(sessions) do
    sessions
    |> Map.values()
    |> Enum.sort_by(
      fn entry ->
        # Use epoch for nil timestamps to sort them last
        case entry.last_message_at do
          nil -> ~N[1970-01-01 00:00:00]
          dt -> dt
        end
      end,
      {:desc, NaiveDateTime}
    )
    |> Enum.map(fn entry ->
      %{
        "session_id" => entry.session_id,
        "other_participant_id" => entry.other_participant_id,
        "last_message" => entry.last_message,
        "last_message_at" => encode_datetime(entry.last_message_at)
      }
    end)
  end

  defp broadcast_snapshot(participant_id, snapshot) do
    Phoenix.PubSub.broadcast(@pubsub, "inbox:#{participant_id}", {:inbox_snapshot, snapshot})
  end

  defp schedule_inactivity_check do
    Process.send_after(self(), :inactivity_check, @inactivity_timeout)
  end

  defp reset_inactivity_timer(state) do
    if state.inactivity_timer do
      Process.cancel_timer(state.inactivity_timer)
    end

    %{
      state
      | inactivity_timer: schedule_inactivity_check(),
        last_activity: System.monotonic_time(:millisecond)
    }
  end

  defp encode_datetime(nil), do: nil
  defp encode_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp encode_datetime(%NaiveDateTime{} = naive), do: NaiveDateTime.to_iso8601(naive)

  defp parse_datetime(nil), do: nil

  defp parse_datetime(iso_string) when is_binary(iso_string) do
    case NaiveDateTime.from_iso8601(iso_string) do
      {:ok, naive} -> naive
      _ -> nil
    end
  end

  defp parse_datetime(%NaiveDateTime{} = naive), do: naive

  defp parse_datetime(%DateTime{} = dt) do
    DateTime.to_naive(dt)
  end
end