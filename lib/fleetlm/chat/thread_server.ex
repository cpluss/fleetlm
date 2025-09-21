defmodule Fleetlm.Chat.ThreadServer do
  @moduledoc false

  use GenServer, restart: :temporary

  require Logger

  import Ecto.Query

  alias Fleetlm.Cache
  alias Fleetlm.Chat
  alias Fleetlm.Chat.ThreadSupervisor
  alias Fleetlm.Chat.Threads.{Message, Participant, Thread}
  alias Fleetlm.Repo
  alias Fleetlm.Telemetry
  alias Phoenix.PubSub

  @registry Fleetlm.Chat.ThreadRegistry
  @pubsub Fleetlm.PubSub
  @cache_limit 40
  @default_timeout 5_000

  ## Public API

  def child_spec(thread_id) when is_binary(thread_id) do
    %{
      id: {__MODULE__, thread_id},
      start: {__MODULE__, :start_link, [[thread_id: thread_id]]},
      restart: :temporary,
      shutdown: 10_000,  # Increased shutdown time for graceful cleanup
      type: :worker
    }
  end

  def start_link(opts) when is_list(opts) do
    thread_id = Keyword.fetch!(opts, :thread_id)
    GenServer.start_link(__MODULE__, thread_id, name: via_tuple(thread_id))
  end

  def ensure(thread_id) when is_binary(thread_id) do
    case Registry.lookup(@registry, thread_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        case ThreadSupervisor.start_thread(thread_id) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def send_message(thread_id, attrs, opts \\ []) do
    with {:ok, _pid} <- ensure(thread_id) do
      GenServer.call(via_tuple(thread_id), {:send_message, attrs, opts}, call_timeout(opts))
    end
  end

  def tick(thread_id, participant_id, cursor \\ nil, opts \\ []) do
    with {:ok, _pid} <- ensure(thread_id) do
      GenServer.call(via_tuple(thread_id), {:tick, participant_id, cursor}, call_timeout(opts))
    end
  end

  ## GenServer callbacks

  @impl true
  def init(thread_id) do
    Process.flag(:trap_exit, true)

    case Repo.get(Thread, thread_id) do
      %Thread{} ->
        :ok

      nil ->
        Logger.warning("thread server init failed: missing thread #{thread_id}")
        {:stop, :not_found}
    end

    # Warm the cache with recent messages and participants
    warm_cache(thread_id)

    state = %{
      thread_id: thread_id,
      last_active_at: DateTime.utc_now()
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:send_message, attrs, opts}, _from, state) do
    start_time = System.monotonic_time(:millisecond)
    attrs = Map.put_new(attrs, :thread_id, state.thread_id)

    case Chat.send_message(attrs, opts) do
      {:ok, %Message{} = message} ->
        # Update caches
        Cache.add_message(state.thread_id, message)
        Cache.update_thread_meta(state.thread_id, message)
        refresh_participants_cache(state.thread_id)

        broadcast_thread(message)
        broadcast_participants(state, message)

        duration = System.monotonic_time(:millisecond) - start_time
        Telemetry.emit_message_sent(
          state.thread_id,
          message.sender_id,
          message.role,
          duration
        )

        {:reply, {:ok, message}, %{state | last_active_at: DateTime.utc_now()}}

      {:error, _step, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:tick, participant_id, cursor}, _from, state) do
    cursor = normalize_cursor(cursor)

    # Check if participant is in thread using cache
    participants = Cache.get_participants(state.thread_id) || refresh_participants_cache(state.thread_id)
    member? = participant_id in participants

    if member? do
      case Cache.get_thread_meta(state.thread_id) do
        nil ->
          {:reply, :idle, state}

        %{last_message_at: last_message_at} when not is_nil(last_message_at) ->
          if is_nil(cursor) or DateTime.compare(last_message_at, cursor) == :gt do
            payload = tick_payload(state.thread_id, participant_id)
            {:reply, {:updated, payload}, %{state | last_active_at: DateTime.utc_now()}}
          else
            {:reply, :idle, state}
          end

        _ ->
          {:reply, :idle, state}
      end
    else
      {:reply, {:error, :not_participant}, state}
    end
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, state) do
    Logger.debug(
      "linked process exited in thread #{state.thread_id}: #{inspect(pid)} #{inspect(reason)}"
    )

    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.debug("ThreadServer terminating for thread #{state.thread_id}: #{inspect(reason)}")

    # Optionally save state or perform cleanup here
    # For now, we rely on the distributed cache for persistence

    :ok
  end

  ## Helpers

  defp via_tuple(thread_id), do: {:via, Registry, {@registry, thread_id}}

  defp call_timeout(opts), do: Keyword.get(opts, :timeout, @default_timeout)

  defp warm_cache(thread_id) do
    # Warm message cache
    messages = Chat.list_thread_messages(thread_id, limit: @cache_limit)
    Cache.cache_messages(thread_id, messages)

    # Warm participants cache
    participants = fetch_participant_ids(thread_id)
    Cache.cache_participants(thread_id, participants)

    # Warm thread metadata
    if messages != [] do
      message = List.first(messages)
      Cache.update_thread_meta(thread_id, message)
    end

    :ok
  end

  defp refresh_participants_cache(thread_id) do
    participants = fetch_participant_ids(thread_id)
    Cache.cache_participants(thread_id, participants)
    participants
  end

  defp fetch_participant_ids(thread_id) do
    Participant
    |> where(thread_id: ^thread_id)
    |> select([p], p.participant_id)
    |> Repo.all()
  end

  defp broadcast_thread(message) do
    PubSub.broadcast(@pubsub, thread_topic(message.thread_id), {:thread_message, message})
  end

  defp broadcast_participants(state, message) do
    base_summary = %{
      thread_id: state.thread_id,
      last_message_at: message.created_at,
      last_message_preview: message.text,
      sender_id: message.sender_id
    }

    participants = Cache.get_participants(state.thread_id) || []

    Enum.each(participants, fn participant_id ->
      summary = Map.put(base_summary, :participant_id, participant_id)
      PubSub.broadcast(@pubsub, participant_topic(participant_id), {:thread_updated, summary})
    end)
  end

  defp tick_payload(thread_id, participant_id) do
    meta = Cache.get_thread_meta(thread_id)
    recent_messages = Cache.get_messages(thread_id, 5) || []

    %{
      thread_id: thread_id,
      participant_id: participant_id,
      last_message_at: meta && meta.last_message_at,
      recent_messages: recent_messages
    }
  end

  defp thread_topic(thread_id), do: "thread:" <> thread_id
  defp participant_topic(participant_id), do: "participant:" <> participant_id


  defp normalize_cursor(nil), do: nil

  defp normalize_cursor(%DateTime{} = cursor) do
    DateTime.truncate(cursor, :microsecond)
  end

  defp normalize_cursor(%NaiveDateTime{} = cursor) do
    cursor
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.truncate(:microsecond)
  end

  defp normalize_cursor(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.truncate(datetime, :microsecond)
      {:error, _} -> nil
    end
  end

  defp normalize_cursor(_), do: nil
end
