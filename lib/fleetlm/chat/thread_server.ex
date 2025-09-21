defmodule Fleetlm.Chat.ThreadServer do
  @moduledoc false

  use GenServer, restart: :temporary

  require Logger

  import Ecto.Query

  alias Fleetlm.Chat
  alias Fleetlm.Chat.ThreadSupervisor
  alias Fleetlm.Chat.Threads.{Message, Participant, Thread}
  alias Fleetlm.Repo
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
      shutdown: 5_000,
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

    messages = Chat.list_thread_messages(thread_id, limit: @cache_limit)
    participants = fetch_participant_ids(thread_id)

    state = %{
      thread_id: thread_id,
      messages: messages,
      participants: MapSet.new(participants),
      last_message_at: last_message_at(messages)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:send_message, attrs, opts}, _from, state) do
    attrs = Map.put_new(attrs, :thread_id, state.thread_id)

    case Chat.send_message(attrs, opts) do
      {:ok, %Message{} = message} ->
        state =
          state
          |> cache_message(message)
          |> refresh_participants()

        broadcast_thread(message)
        broadcast_participants(state, message)

        {:reply, {:ok, message}, %{state | last_message_at: message.created_at}}

      {:error, _step, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:tick, participant_id, cursor}, _from, state) do
    cursor = normalize_cursor(cursor)
    {state, member?} = ensure_participant_cached(state, participant_id)

    if member? do
      cond do
        is_nil(state.last_message_at) ->
          {:reply, :idle, state}

        is_nil(cursor) or DateTime.compare(state.last_message_at, cursor) == :gt ->
          payload = tick_payload(state, participant_id)
          {:reply, {:updated, payload}, state}

        true ->
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

  ## Helpers

  defp via_tuple(thread_id), do: {:via, Registry, {@registry, thread_id}}

  defp call_timeout(opts), do: Keyword.get(opts, :timeout, @default_timeout)

  defp cache_message(state, message) do
    messages = [message | state.messages] |> Enum.take(@cache_limit)
    %{state | messages: messages}
  end

  defp refresh_participants(state) do
    participants = fetch_participant_ids(state.thread_id)
    %{state | participants: MapSet.new(participants)}
  end

  defp ensure_participant_cached(state, participant_id) do
    if MapSet.member?(state.participants, participant_id) do
      {state, true}
    else
      state = refresh_participants(state)
      {state, MapSet.member?(state.participants, participant_id)}
    end
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

    Enum.each(state.participants, fn participant_id ->
      summary = Map.put(base_summary, :participant_id, participant_id)
      PubSub.broadcast(@pubsub, participant_topic(participant_id), {:thread_updated, summary})
    end)
  end

  defp tick_payload(state, participant_id) do
    %{
      thread_id: state.thread_id,
      participant_id: participant_id,
      last_message_at: state.last_message_at,
      recent_messages: Enum.take(state.messages, 5)
    }
  end

  defp thread_topic(thread_id), do: "thread:" <> thread_id
  defp participant_topic(participant_id), do: "participant:" <> participant_id

  defp last_message_at([]), do: nil
  defp last_message_at([message | _]), do: message.created_at

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
