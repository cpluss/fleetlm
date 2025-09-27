defmodule Fleetlm.Runtime.SessionServer do
  @moduledoc """
  Per-session GenServer responsible for orchestrating runtime state.

  Each active session has a dedicated process that:
  * Hydrates and maintains the cached tail in Cachex
  * Broadcasts session messages via `Fleetlm.Runtime.Events`
  * Provides a lightweight `load_tail/1` API for channel joins

  The server does **not** own persistence—that work happens in
  `Fleetlm.Sessions.append_message/2`—but it reacts to persisted changes to
  keep the runtime consistent and fan-out real-time updates.
  """

  use GenServer, restart: :transient

  alias Fleetlm.Sessions
  alias Fleetlm.Runtime.Cache
  alias Fleetlm.Runtime.Events
  alias Fleetlm.Runtime.SessionSupervisor
  alias Fleetlm.Observability

  @tail_limit 100

  @spec start_link(String.t()) :: GenServer.on_start()
  def start_link(session_id) when is_binary(session_id) do
    GenServer.start_link(__MODULE__, session_id, name: via(session_id))
  end

  @spec append_message(map()) :: :ok
  def append_message(%{session_id: session_id} = message) when is_binary(session_id) do
    SessionSupervisor.ensure_started(session_id)
    GenServer.cast(via(session_id), {:append, message})
  end

  @spec load_tail(String.t()) :: {:ok, [map()]} | {:error, term()}
  def load_tail(session_id) do
    SessionSupervisor.ensure_started(session_id)
    GenServer.call(via(session_id), :tail)
  end

  @doc """
  Calculate unread count for a participant from cached messages.
  Returns the count if session is active, nil if not running (caller should use database).
  """
  @spec cached_unread_count(String.t(), String.t(), DateTime.t() | NaiveDateTime.t() | nil) ::
          non_neg_integer() | nil
  def cached_unread_count(session_id, participant_id, last_read_at) do
    case GenServer.whereis(via(session_id)) do
      # Session not running, caller should use database
      nil ->
        nil

      _pid ->
        try do
          GenServer.call(via(session_id), {:unread_count, participant_id, last_read_at}, 1000)
        catch
          # Process died or timeout, use database fallback
          :exit, _ -> nil
        end
    end
  end

  @doc """
  Get inbox metadata (last message info) from cached messages.
  Returns metadata if session is active, nil if not running.
  """
  @spec cached_inbox_metadata(String.t()) :: map() | nil
  def cached_inbox_metadata(session_id) do
    case GenServer.whereis(via(session_id)) do
      nil ->
        nil

      _pid ->
        try do
          GenServer.call(via(session_id), :inbox_metadata, 1000)
        catch
          :exit, _ -> nil
        end
    end
  end

  defp via(session_id), do: {:via, Registry, {Fleetlm.Runtime.SessionRegistry, session_id}}

  @impl true
  def init(session_id) do
    # Enable graceful shutdown for database cleanup during tests
    Process.flag(:trap_exit, true)
    tail = warm_cache(session_id)
    {:ok, %{session_id: session_id, tail: tail}}
  end

  @impl true
  def handle_cast({:append, message}, %{session_id: session_id} = state) do
    _ = Cache.append_to_tail(session_id, message, limit: @tail_limit)
    Events.publish_message(message)
    maybe_record_queue_depth(session_id)

    {:noreply, %{state | tail: Enum.take([message | state.tail], @tail_limit)}}
  end

  @impl true
  def handle_call(:tail, _from, state) do
    {:reply, {:ok, state.tail}, state}
  end

  @impl true
  def handle_call({:unread_count, participant_id, last_read_at}, _from, state) do
    count = calculate_unread_from_cache(state.tail, participant_id, last_read_at)
    {:reply, count, state}
  end

  @impl true
  def handle_call(:inbox_metadata, _from, state) do
    metadata = extract_inbox_metadata(state.tail)
    {:reply, metadata, state}
  end

  @impl true
  def handle_info({:EXIT, _pid, _reason}, state) do
    # Handle EXIT messages from trap_exit gracefully
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    # Clean up cached data on shutdown
    Cache.delete_tail(state.session_id)
    :ok
  end

  defp warm_cache(session_id) do
    case Cache.fetch_tail(session_id, limit: @tail_limit) do
      {:ok, messages} ->
        messages

      :miss ->
        messages = preload_tail(session_id)
        _ = Cache.put_tail(session_id, messages)
        messages

      {:error, _reason} ->
        messages = preload_tail(session_id)
        _ = Cache.put_tail(session_id, messages)
        messages
    end
  end

  defp preload_tail(session_id) do
    session = Sessions.get_session!(session_id)

    Sessions.list_messages(session_id, limit: @tail_limit)
    |> Enum.map(fn message ->
      message
      |> Map.from_struct()
      |> Map.put(:session, session)
    end)
    |> Enum.reverse()
  end

  defp calculate_unread_from_cache(messages, participant_id, last_read_at) do
    cutoff_time = normalize_datetime(last_read_at)

    messages
    |> Enum.filter(fn message ->
      # Count messages not sent by this participant
      # And messages after their last read time
      message.sender_id != participant_id and
        (cutoff_time == nil or datetime_after?(message.inserted_at, cutoff_time))
    end)
    |> length()
  end

  defp extract_inbox_metadata([]), do: %{last_message_at: nil, last_message_id: nil}

  defp extract_inbox_metadata([latest | _]) do
    %{
      last_message_at: latest.inserted_at,
      last_message_id: latest.id
    }
  end

  defp normalize_datetime(nil), do: nil
  defp normalize_datetime(%DateTime{} = dt), do: DateTime.to_naive(dt)
  defp normalize_datetime(%NaiveDateTime{} = naive), do: naive

  defp datetime_after?(message_time, cutoff_time) do
    message_naive = normalize_datetime(message_time)
    cutoff_naive = normalize_datetime(cutoff_time)

    case {message_naive, cutoff_naive} do
      {nil, _} -> false
      {_, nil} -> true
      {msg, cutoff} -> NaiveDateTime.compare(msg, cutoff) == :gt
    end
  end

  defp maybe_record_queue_depth(session_id) do
    case Process.info(self(), :message_queue_len) do
      {:message_queue_len, queue_len} when is_integer(queue_len) and queue_len >= 0 ->
        Observability.record_session_queue_depth(session_id, queue_len)

      _ ->
        :ok
    end
  end
end
