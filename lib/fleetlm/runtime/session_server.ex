defmodule Fleetlm.Runtime.SessionServer do
  @moduledoc """
  Owner process for a session. Runs on the owner node determined by HashRing.

  Responsibilities:
  - Sequence number management (monotonically increasing per session)
  - Message append via Storage.API (disk log + async postgres)
  - Local ETS tail cache (last 64 messages for quick replay)
  - PubSub broadcast after append
  - Agent dispatcher trigger
  - Graceful drain on shutdown
  - Inactivity timeout (15 min -> shutdown, marks session inactive)

  Lifecycle:
  - Started lazily on first message/join
  - Marks session "active" in DB on init
  - Shuts down after 15 min inactivity
  - Marks session "inactive" in DB on terminate
  """

  use GenServer, restart: :transient
  require Logger

  alias Fleetlm.Storage
  alias Fleetlm.Runtime.HashRing
  alias Fleetlm.Runtime.SessionTracker

  # How many messages to keep in the tail cache in memory
  # to avoid fetching all messages from storage on each session join
  # or replay (e.g. as when we send a lot of messages to the backing agent webhook).
  @tail_size Application.compile_env(:fleetlm, :session_server_tail_size, 128)
  # How long to wait before shutting down the session if it's inactive.
  @inactivity_timeout Application.compile_env(
                        :fleetlm,
                        :session_server_inactivity_timeout,
                        :timer.minutes(15)
                      )

  defstruct [
    :session_id,
    :user_id,
    :agent_id,
    :slot,
    :seq,
    :tail_table,
    :inactivity_timer,
    :last_activity
  ]

  @type state :: %__MODULE__{
          session_id: String.t(),
          user_id: String.t(),
          agent_id: String.t(),
          # Shard slot number for the session, note that this is
          # not the slot of the underlying storage slot.
          slot: non_neg_integer(),
          # Last sequence number seen - to be incremented on each append
          # for total ordering.
          seq: non_neg_integer(),
          # Ets table to track the tail of most recent messages within
          # the session.
          tail_table: :ets.tid(),
          # Used to detect inactivity and shutdown the session after a few minutes
          # to avoid holding onto resources (e.g. its message tail).
          inactivity_timer: reference() | nil,
          last_activity: integer()
        }

  # Client API

  @spec start_link(String.t()) :: GenServer.on_start()
  def start_link(session_id) when is_binary(session_id) do
    GenServer.start_link(__MODULE__, session_id, name: via(session_id))
  end

  @spec append_message(String.t(), String.t(), String.t(), term(), term()) ::
          {:ok, map()} | {:error, term()}
  def append_message(session_id, sender_id, kind, content, metadata \\ %{}) do
    GenServer.call(
      via(session_id),
      {:append, sender_id, kind, content, metadata},
      :timer.seconds(10)
    )
  end

  @spec join(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def join(session_id, user_id, opts \\ []) do
    GenServer.call(via(session_id), {:join, user_id, opts}, :timer.seconds(10))
  end

  @spec drain(String.t()) :: :ok
  def drain(session_id) do
    GenServer.call(via(session_id), :drain, :timer.seconds(10))
  end

  # Gen Server callbacks

  @impl true
  def init(session_id) do
    Process.flag(:trap_exit, true)

    # Verify we're on the correct owner node
    slot = HashRing.slot_for_session(session_id)
    expected_owner = HashRing.owner_node(slot)

    if expected_owner != Node.self() do
      Logger.error(
        "SessionServer #{session_id} started on wrong node. Expected: #{expected_owner}"
      )

      {:stop, {:wrong_owner, expected_owner}}
    else
      # Load session from database
      case load_session(session_id) do
        {:ok, session} ->
          # Create ETS table for tail cache
          tail_table = :ets.new(:session_tail, [:ordered_set, :private])

          # Get current sequence number (max from storage)
          seq = get_current_seq(session_id)

          # Mark session as active
          mark_session_active(session_id)

          # Schedule inactivity check
          timer = schedule_inactivity_check()

          Logger.info(
            "SessionServer started: #{session_id} on node #{Node.self()} (slot: #{slot}, seq: #{seq})"
          )

          # Track this session as :running in the distributed tracker
          SessionTracker.track(self(), session_id, %{
            node: Node.self(),
            status: :running
          })

          {:ok,
           %__MODULE__{
             session_id: session_id,
             user_id: session.user_id,
             agent_id: session.agent_id,
             slot: slot,
             seq: seq,
             tail_table: tail_table,
             inactivity_timer: timer,
             last_activity: System.monotonic_time(:millisecond)
           }}

        {:error, reason} ->
          Logger.error("Failed to load session #{session_id}: #{inspect(reason)}")
          {:stop, {:session_not_found, reason}}
      end
    end
  end

  @impl true
  def handle_call({:append, sender_id, kind, content, metadata}, _from, state) do
    # Increment sequence
    next_seq = state.seq + 1

    # Determine recipient_id based on sender (flip between user and agent)
    recipient_id =
      if sender_id == state.user_id, do: state.agent_id, else: state.user_id

    # Append via Storage.API (writes to disk log)
    case Storage.append_message(
           state.session_id,
           next_seq,
           sender_id,
           recipient_id,
           kind,
           content,
           metadata
         ) do
      :ok ->
        # Build message for broadcasting/caching
        message = %{
          id: Uniq.UUID.uuid7(:slug),
          session_id: state.session_id,
          seq: next_seq,
          sender_id: sender_id,
          kind: kind,
          content: content,
          metadata: metadata,
          inserted_at: NaiveDateTime.utc_now()
        }

        # Emit message throughput telemetry (messages/second metric)
        Fleetlm.Observability.Telemetry.emit_message_throughput()

        # Update local tail cache
        :ets.insert(state.tail_table, {next_seq, message})
        trim_tail(state.tail_table)

        # Broadcast to session channel (for active session participants)
        Phoenix.PubSub.broadcast(
          Fleetlm.PubSub,
          "session:#{state.session_id}",
          {:session_message, format_message(message)}
        )

        # Broadcast notification to user's inbox (agents don't have inboxes - they use webhooks)
        notification = %{
          "session_id" => state.session_id,
          "user_id" => state.user_id,
          "agent_id" => state.agent_id,
          "message_sender" => sender_id,
          "timestamp" => message.inserted_at
        }

        Phoenix.PubSub.broadcast(
          Fleetlm.PubSub,
          "user:#{state.user_id}:inbox",
          {:message_notification, notification}
        )

        # Dispatch to agent if sender is user and agent exists (and not same id)
        if sender_id == state.user_id and state.agent_id != nil and sender_id != state.agent_id do
          Fleetlm.Agent.Engine.enqueue(state.session_id, state.agent_id, state.user_id, next_seq)
        end

        # Reset inactivity timer
        new_state = reset_inactivity_timer(state)

        {:reply, {:ok, message}, %{new_state | seq: next_seq}}

      {:error, reason} = error ->
        Logger.error(
          "Failed to append message to session #{state.session_id}: #{inspect(reason)}"
        )

        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:join, user_id, opts}, _from, state) do
    # Authorize - only the user can join (agents receive via webhooks)
    unless user_id == state.user_id do
      {:reply, {:error, :unauthorized}, state}
    else
      last_seq = Keyword.get(opts, :last_seq, 0)
      limit = Keyword.get(opts, :limit, 100)

      # Get messages from storage (disk log + DB fallback)
      {:ok, messages} = Storage.get_messages(state.session_id, last_seq, limit)

      # Convert to channel format
      formatted_messages = Enum.map(messages, &format_storage_message/1)

      # Reset inactivity timer
      new_state = reset_inactivity_timer(state)

      {:reply, {:ok, %{messages: formatted_messages}}, new_state}
    end
  end

  @impl true
  def handle_call(:drain, _from, state) do
    Logger.info("Draining session #{state.session_id}")

    # Flush storage synchronously (best effort - proceed even on timeout)
    case flush_session_sync(state.session_id) do
      :ok ->
        Logger.debug("Session #{state.session_id} storage flushed successfully")

      :error ->
        Logger.error(
          "Session #{state.session_id} storage flush timed out, proceeding with drain anyway"
        )
    end

    # Mark session inactive
    mark_session_inactive(state.session_id)

    # Broadcast drain event
    Phoenix.PubSub.broadcast(
      Fleetlm.PubSub,
      "session:#{state.session_id}",
      {:session_drain, state.session_id}
    )

    # Stop the process (tracker will auto-remove on termination)
    {:stop, :normal, :ok, state}
  end

  @impl true
  def handle_info(:inactivity_check, state) do
    elapsed = System.monotonic_time(:millisecond) - state.last_activity

    if elapsed >= @inactivity_timeout do
      Logger.info("Session #{state.session_id} inactive for #{elapsed}ms, shutting down")
      {:stop, :normal, state}
    else
      # Reschedule check
      timer = schedule_inactivity_check()
      {:noreply, %{state | inactivity_timer: timer}}
    end
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("SessionServer terminating: #{state.session_id}, reason: #{inspect(reason)}")

    # Flush storage if not already drained
    flush_session_sync(state.session_id)

    # Mark session inactive (skip in tests to avoid DB ownership issues)
    unless Application.get_env(:fleetlm, :skip_terminate_db_ops, false) do
      mark_session_inactive(state.session_id)
    end

    # Clean up ETS table
    :ets.delete(state.tail_table)

    :ok
  end

  # Private helpers

  defp via(session_id) do
    {:via, Registry, {Fleetlm.Runtime.SessionRegistry, session_id}}
  end

  defp load_session(session_id) do
    try do
      # Load session from new storage model
      case Fleetlm.Repo.get(Fleetlm.Storage.Model.Session, session_id) do
        nil -> {:error, :not_found}
        session -> {:ok, session}
      end
    rescue
      Ecto.NoResultsError -> {:error, :not_found}
    end
  end

  defp mark_session_active(session_id) do
    Fleetlm.Repo.get(Fleetlm.Storage.Model.Session, session_id)
    |> case do
      nil ->
        :ok

      session ->
        session
        |> Ecto.Changeset.change(%{status: "active"})
        |> Fleetlm.Repo.update()
    end
  end

  defp mark_session_inactive(session_id) do
    Fleetlm.Repo.get(Fleetlm.Storage.Model.Session, session_id)
    |> case do
      nil ->
        :ok

      session ->
        session
        |> Ecto.Changeset.change(%{status: "inactive"})
        |> Fleetlm.Repo.update()
    end
  end

  defp get_current_seq(session_id) do
    # Get max seq directly from DB (more efficient than fetching all messages)
    import Ecto.Query

    case Fleetlm.Storage.Model.Message
         |> where([m], m.session_id == ^session_id)
         |> select([m], max(m.seq))
         |> Fleetlm.Repo.one() do
      nil -> 0
      seq when is_integer(seq) -> seq
    end
  end

  defp trim_tail(table) do
    case :ets.info(table, :size) do
      size when size > @tail_size ->
        # Delete oldest entries
        to_delete = size - @tail_size

        :ets.first(table)
        |> delete_n_entries(table, to_delete)

      _ ->
        :ok
    end
  end

  defp delete_n_entries(:"$end_of_table", _table, _n), do: :ok
  defp delete_n_entries(_key, _table, 0), do: :ok

  defp delete_n_entries(key, table, n) do
    next = :ets.next(table, key)
    :ets.delete(table, key)
    delete_n_entries(next, table, n - 1)
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

  defp flush_session_sync(session_id) do
    case Fleetlm.Storage.flush_session(session_id) do
      :ok ->
        :ok

      :already_clean ->
        :ok

      {:error, reason} ->
        Logger.error("Flush failed for session #{session_id}: #{inspect(reason)}")
        :error
    end
  end

  defp format_message(message) do
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

  defp format_storage_message(message) do
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

  defp encode_datetime(nil), do: nil
  defp encode_datetime(%NaiveDateTime{} = naive), do: NaiveDateTime.to_iso8601(naive)
  defp encode_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
