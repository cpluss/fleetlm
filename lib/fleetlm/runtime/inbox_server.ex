defmodule Fleetlm.Runtime.InboxServer do
  @moduledoc """
  Event-driven inbox server for a user.

  Note: Agents do NOT have inboxes - they communicate via webhooks only.

  Responsibilities:
  - Subscribe to PubSub notifications for all user's sessions
  - Maintain inbox state (last message, unread count per session)
  - Broadcast inbox deltas via PubSub when messages arrive
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
  # 1 second
  @batch_interval 1_000
  # Broadcast immediately if 50+ dirty sessions
  @batch_threshold 50

  @pubsub Fleetlm.PubSub

  defstruct [
    :user_id,
    :sessions,
    :dirty_sessions,
    :batch_timer,
    :inactivity_timer,
    :last_activity
  ]

  @type session_entry :: %{
          session_id: String.t(),
          agent_id: String.t(),
          unread_count: non_neg_integer(),
          last_activity_at: NaiveDateTime.t() | nil,
          last_sender_id: String.t() | nil
        }

  @type state :: %__MODULE__{
          user_id: String.t(),
          sessions: %{String.t() => session_entry()},
          dirty_sessions: MapSet.t(),
          batch_timer: reference() | nil,
          inactivity_timer: reference() | nil,
          last_activity: integer()
        }

  # Client API

  @spec start_link(String.t()) :: GenServer.on_start()
  def start_link(user_id) when is_binary(user_id) do
    GenServer.start_link(__MODULE__, user_id, name: via(user_id))
  end

  @spec get_snapshot(String.t()) :: {:ok, [map()]} | {:error, term()}
  def get_snapshot(user_id) do
    GenServer.call(via(user_id), :get_snapshot, :timer.seconds(5))
  end

  # Server callbacks

  @impl true
  def init(user_id) do
    Process.flag(:trap_exit, true)

    # Load all user sessions (DB query on init only)
    {:ok, sessions_list} = StorageAPI.get_sessions_for_user(user_id)

    # Subscribe to user's inbox notification topic
    Phoenix.PubSub.subscribe(@pubsub, "user:#{user_id}:inbox")

    # Build session state
    sessions =
      sessions_list
      |> Enum.map(fn session ->
        entry = %{
          session_id: session.id,
          agent_id: session.agent_id,
          unread_count: 0,
          last_activity_at: nil,
          last_sender_id: nil
        }

        {session.id, entry}
      end)
      |> Enum.into(%{})

    inactivity_timer = schedule_inactivity_check()
    batch_timer = schedule_batch_broadcast()

    Logger.info("InboxServer started for user #{user_id} with #{map_size(sessions)} sessions")

    {:ok,
     %__MODULE__{
       user_id: user_id,
       sessions: sessions,
       dirty_sessions: MapSet.new(),
       batch_timer: batch_timer,
       inactivity_timer: inactivity_timer,
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
  def handle_info({:message_notification, notification}, state) do
    session_id = notification["session_id"]

    # Check if this is an existing session or new
    case Map.get(state.sessions, session_id) do
      nil ->
        # New session - add it to our state
        Logger.debug("InboxServer user #{state.user_id}: new session #{session_id}")

        entry = %{
          session_id: session_id,
          agent_id: notification["agent_id"],
          unread_count: 1,
          last_activity_at: parse_datetime(notification["timestamp"]),
          last_sender_id: notification["message_sender"]
        }

        new_sessions = Map.put(state.sessions, session_id, entry)
        new_dirty = MapSet.put(state.dirty_sessions, session_id)

        new_state =
          if MapSet.size(new_dirty) >= @batch_threshold do
            flush_batch(%{state | sessions: new_sessions, dirty_sessions: new_dirty})
          else
            %{state | sessions: new_sessions, dirty_sessions: new_dirty}
          end

        {:noreply, reset_inactivity_timer(new_state)}

      entry ->
        # Existing session - increment counters
        updated_entry = %{
          entry
          | unread_count: entry.unread_count + 1,
            last_activity_at: parse_datetime(notification["timestamp"]),
            last_sender_id: notification["message_sender"]
        }

        new_sessions = Map.put(state.sessions, session_id, updated_entry)
        new_dirty = MapSet.put(state.dirty_sessions, session_id)

        # Check if we hit threshold → broadcast immediately
        new_state =
          if MapSet.size(new_dirty) >= @batch_threshold do
            flush_batch(%{state | sessions: new_sessions, dirty_sessions: new_dirty})
          else
            %{state | sessions: new_sessions, dirty_sessions: new_dirty}
          end

        {:noreply, reset_inactivity_timer(new_state)}
    end
  end

  @impl true
  def handle_info(:batch_broadcast, state) do
    new_state = flush_batch(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:inactivity_check, state) do
    elapsed = System.monotonic_time(:millisecond) - state.last_activity

    if elapsed >= @inactivity_timeout do
      Logger.info("InboxServer #{state.user_id} inactive for #{elapsed}ms, shutting down")
      {:stop, :normal, state}
    else
      timer = schedule_inactivity_check()
      {:noreply, %{state | inactivity_timer: timer}}
    end
  end

  @impl true
  def terminate(_reason, state) do
    Logger.info("InboxServer terminating for user #{state.user_id}")

    # Cancel timers
    if state.batch_timer, do: Process.cancel_timer(state.batch_timer)
    if state.inactivity_timer, do: Process.cancel_timer(state.inactivity_timer)

    :ok
  end

  # Private helpers

  defp via(user_id) do
    {:via, Registry, {Fleetlm.Runtime.InboxRegistry, user_id}}
  end

  defp flush_batch(state) do
    if MapSet.size(state.dirty_sessions) > 0 do
      snapshot = build_snapshot(state.sessions)
      broadcast_snapshot(state.user_id, snapshot)

      # Cancel old timer and schedule next batch
      if state.batch_timer do
        Process.cancel_timer(state.batch_timer)
      end

      batch_timer = schedule_batch_broadcast()

      %{state | dirty_sessions: MapSet.new(), batch_timer: batch_timer}
    else
      state
    end
  end

  defp schedule_batch_broadcast do
    Process.send_after(self(), :batch_broadcast, @batch_interval)
  end

  defp build_snapshot(sessions) do
    sessions
    |> Map.values()
    |> Enum.sort_by(
      fn entry ->
        # Use epoch for nil timestamps to sort them last
        case entry.last_activity_at do
          nil -> ~N[1970-01-01 00:00:00]
          dt -> dt
        end
      end,
      {:desc, NaiveDateTime}
    )
    |> Enum.map(fn entry ->
      %{
        "session_id" => entry.session_id,
        "agent_id" => entry.agent_id,
        "unread_count" => entry.unread_count,
        "last_activity_at" => encode_datetime(entry.last_activity_at),
        "last_sender_id" => entry.last_sender_id
      }
    end)
  end

  defp broadcast_snapshot(user_id, snapshot) do
    Phoenix.PubSub.broadcast(@pubsub, "inbox:user:#{user_id}", {:inbox_snapshot, snapshot})
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
