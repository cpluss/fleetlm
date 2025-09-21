defmodule Fleetlm.Cache do
  @moduledoc """
  Cache layer for FleetLM using Cachex.

  Provides distributed caching for:
  - Recent messages (per thread)
  - Thread participants
  - Thread metadata
  """

  alias Fleetlm.Chat.Threads.{Message, Participant}
  alias Fleetlm.Telemetry

  # Cache names
  @messages_cache :fleetlm_messages
  @participants_cache :fleetlm_participants
  @thread_meta_cache :fleetlm_thread_meta

  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, []},
      type: :supervisor
    }
  end

  def start_link do
    children = [
      # Messages cache: TTL 1 hour, LRU with 10k max entries per thread
      Supervisor.child_spec(
        {Cachex, name: @messages_cache, limit: 10_000},
        id: :messages_cache
      ),

      # Participants cache: TTL 30 minutes, smaller cache for participant lists
      Supervisor.child_spec(
        {Cachex, name: @participants_cache, limit: 5_000},
        id: :participants_cache
      ),

      # Thread metadata cache: TTL 15 minutes, for last_message_at etc
      Supervisor.child_spec(
        {Cachex, name: @thread_meta_cache, limit: 5_000},
        id: :thread_meta_cache
      )
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__)
  end

  ## Messages Cache

  @doc "Cache recent messages for a thread"
  def cache_messages(thread_id, messages) when is_list(messages) do
    key = messages_key(thread_id)
    Cachex.put(@messages_cache, key, messages, ttl: :timer.hours(1))
  end

  @doc "Get cached messages for a thread"
  def get_messages(thread_id, limit \\ 40) do
    key = messages_key(thread_id)
    start_time = System.monotonic_time(:microsecond)

    result = case Cachex.get(@messages_cache, key) do
      {:ok, nil} ->
        Telemetry.emit_cache_event(:miss, @messages_cache, key, time_diff(start_time))
        nil
      {:ok, messages} ->
        Telemetry.emit_cache_event(:hit, @messages_cache, key, time_diff(start_time))
        Enum.take(messages, limit)
      {:error, _} ->
        Telemetry.emit_cache_event(:miss, @messages_cache, key, time_diff(start_time))
        nil
    end

    result
  end

  @doc "Add a single message to thread cache"
  def add_message(thread_id, %Message{} = message) do
    key = messages_key(thread_id)

    case Cachex.get(@messages_cache, key) do
      {:ok, nil} ->
        Cachex.put(@messages_cache, key, [message], ttl: :timer.hours(1))

      {:ok, existing_messages} ->
        # Prepend new message and limit to reasonable size
        updated = [message | existing_messages] |> Enum.take(100)
        Cachex.put(@messages_cache, key, updated, ttl: :timer.hours(1))

      {:error, _} ->
        :error
    end
  end

  @doc "Invalidate message cache for a thread"
  def invalidate_messages(thread_id) do
    key = messages_key(thread_id)
    Cachex.del(@messages_cache, key)
  end

  ## Participants Cache

  @doc "Cache participants for a thread"
  def cache_participants(thread_id, participants) when is_list(participants) do
    key = participants_key(thread_id)
    participant_ids = Enum.map(participants, fn
      %Participant{participant_id: id} -> id
      id when is_binary(id) -> id
    end)
    Cachex.put(@participants_cache, key, participant_ids, ttl: :timer.minutes(30))
  end

  @doc "Get cached participant IDs for a thread"
  def get_participants(thread_id) do
    key = participants_key(thread_id)

    case Cachex.get(@participants_cache, key) do
      {:ok, nil} -> nil
      {:ok, participant_ids} -> participant_ids
      {:error, _} -> nil
    end
  end

  @doc "Invalidate participants cache for a thread"
  def invalidate_participants(thread_id) do
    key = participants_key(thread_id)
    Cachex.del(@participants_cache, key)
  end

  ## Thread Metadata Cache

  @doc "Cache thread metadata (last_message_at, etc)"
  def cache_thread_meta(thread_id, meta) when is_map(meta) do
    key = thread_meta_key(thread_id)
    Cachex.put(@thread_meta_cache, key, meta, ttl: :timer.minutes(15))
  end

  @doc "Get cached thread metadata"
  def get_thread_meta(thread_id) do
    key = thread_meta_key(thread_id)

    case Cachex.get(@thread_meta_cache, key) do
      {:ok, nil} -> nil
      {:ok, meta} -> meta
      {:error, _} -> nil
    end
  end

  @doc "Update thread metadata with new message info"
  def update_thread_meta(thread_id, %Message{} = message) do
    key = thread_meta_key(thread_id)

    meta = %{
      last_message_at: message.created_at,
      last_message_preview: message.text,
      sender_id: message.sender_id
    }

    Cachex.put(@thread_meta_cache, key, meta, ttl: :timer.minutes(15))
  end

  @doc "Invalidate thread metadata cache"
  def invalidate_thread_meta(thread_id) do
    key = thread_meta_key(thread_id)
    Cachex.del(@thread_meta_cache, key)
  end

  ## Cache Statistics

  @doc "Get cache statistics for monitoring"
  def stats do
    %{
      messages: cache_stats(@messages_cache),
      participants: cache_stats(@participants_cache),
      thread_meta: cache_stats(@thread_meta_cache)
    }
  end

  ## Private Functions

  defp messages_key(thread_id), do: "messages:#{thread_id}"
  defp participants_key(thread_id), do: "participants:#{thread_id}"
  defp thread_meta_key(thread_id), do: "meta:#{thread_id}"


  defp cache_stats(cache_name) do
    case Cachex.stats(cache_name) do
      {:ok, stats} -> stats
      {:error, _} -> %{}
    end
  end

  defp time_diff(start_time) do
    System.monotonic_time(:microsecond) - start_time
  end
end