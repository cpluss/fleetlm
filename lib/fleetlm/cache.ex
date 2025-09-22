defmodule Fleetlm.Cache do
  @moduledoc """
  Cache layer for FleetLM using Cachex.

  Provides distributed caching for:
  - Recent DM messages (per conversation)
  - Recent broadcast messages
  """

  alias Fleetlm.Chat.{DmMessage, BroadcastMessage}
  alias Fleetlm.Telemetry

  # Cache names
  @dm_messages_cache :fleetlm_dm_messages
  @broadcast_messages_cache :fleetlm_broadcast_messages

  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, []},
      type: :supervisor
    }
  end

  def start_link do
    children = [
      # DM messages cache: TTL 1 hour, LRU with 10k max entries
      Supervisor.child_spec(
        {Cachex, name: @dm_messages_cache, limit: 10_000},
        id: :dm_messages_cache
      ),

      # Broadcast messages cache: TTL 30 minutes, smaller cache
      Supervisor.child_spec(
        {Cachex, name: @broadcast_messages_cache, limit: 5_000},
        id: :broadcast_messages_cache
      )
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__)
  end

  ## DM Messages Cache

  @doc "Cache recent DM messages for a conversation"
  def cache_dm_messages(user_a_id, user_b_id, messages) when is_list(messages) do
    key = dm_messages_key(user_a_id, user_b_id)
    Cachex.put(@dm_messages_cache, key, messages, ttl: :timer.hours(1))
  end

  @doc "Get cached DM messages for a conversation"
  def get_dm_messages(user_a_id, user_b_id, limit \\ 40) do
    key = dm_messages_key(user_a_id, user_b_id)
    start_time = System.monotonic_time(:microsecond)

    result =
      case Cachex.get(@dm_messages_cache, key) do
        {:ok, nil} ->
          Telemetry.emit_cache_event(:miss, @dm_messages_cache, key, time_diff(start_time))
          nil

        {:ok, messages} ->
          Telemetry.emit_cache_event(:hit, @dm_messages_cache, key, time_diff(start_time))
          Enum.take(messages, limit)

        {:error, _} ->
          Telemetry.emit_cache_event(:miss, @dm_messages_cache, key, time_diff(start_time))
          nil
      end

    result
  end

  @doc "Add a single DM message to conversation cache"
  def add_dm_message(%DmMessage{} = message) do
    key = dm_messages_key(message.sender_id, message.recipient_id)

    case Cachex.get(@dm_messages_cache, key) do
      {:ok, nil} ->
        Cachex.put(@dm_messages_cache, key, [message], ttl: :timer.hours(1))

      {:ok, existing_messages} ->
        # Prepend new message and limit to reasonable size
        updated = [message | existing_messages] |> Enum.take(100)
        Cachex.put(@dm_messages_cache, key, updated, ttl: :timer.hours(1))

      {:error, _} ->
        :error
    end
  end

  @doc "Invalidate DM message cache for a conversation"
  def invalidate_dm_messages(user_a_id, user_b_id) do
    key = dm_messages_key(user_a_id, user_b_id)
    Cachex.del(@dm_messages_cache, key)
  end

  ## Broadcast Messages Cache

  @doc "Cache recent broadcast messages"
  def cache_broadcast_messages(messages) when is_list(messages) do
    key = "broadcast_messages"
    Cachex.put(@broadcast_messages_cache, key, messages, ttl: :timer.minutes(30))
  end

  @doc "Get cached broadcast messages"
  def get_broadcast_messages(limit \\ 40) do
    key = "broadcast_messages"
    start_time = System.monotonic_time(:microsecond)

    result =
      case Cachex.get(@broadcast_messages_cache, key) do
        {:ok, nil} ->
          Telemetry.emit_cache_event(:miss, @broadcast_messages_cache, key, time_diff(start_time))
          nil

        {:ok, messages} ->
          Telemetry.emit_cache_event(:hit, @broadcast_messages_cache, key, time_diff(start_time))
          Enum.take(messages, limit)

        {:error, _} ->
          Telemetry.emit_cache_event(:miss, @broadcast_messages_cache, key, time_diff(start_time))
          nil
      end

    result
  end

  @doc "Add a single broadcast message to cache"
  def add_broadcast_message(%BroadcastMessage{} = message) do
    key = "broadcast_messages"

    case Cachex.get(@broadcast_messages_cache, key) do
      {:ok, nil} ->
        Cachex.put(@broadcast_messages_cache, key, [message], ttl: :timer.minutes(30))

      {:ok, existing_messages} ->
        # Prepend new message and limit to reasonable size
        updated = [message | existing_messages] |> Enum.take(100)
        Cachex.put(@broadcast_messages_cache, key, updated, ttl: :timer.minutes(30))

      {:error, _} ->
        :error
    end
  end

  @doc "Invalidate broadcast message cache"
  def invalidate_broadcast_messages do
    key = "broadcast_messages"
    Cachex.del(@broadcast_messages_cache, key)
  end

  ## Cache Statistics

  @doc "Get cache statistics for monitoring"
  def stats do
    %{
      dm_messages: cache_stats(@dm_messages_cache),
      broadcast_messages: cache_stats(@broadcast_messages_cache)
    }
  end

  ## Private Functions

  defp dm_messages_key(user_a_id, user_b_id) do
    [a, b] = Enum.sort([user_a_id, user_b_id])
    "dm_messages:#{a}:#{b}"
  end

  defp cache_stats(cache_name) do
    case Cachex.stats(cache_name) do
      {:ok, stats} -> stats
      {:error, _} -> %{}
    end
  end

  defp time_diff(start_time) do
    System.monotonic_time(:microsecond) - start_time
  end

  # Legacy compatibility functions - do nothing but don't break
  def get_messages(_thread_id, _limit \\ 40), do: nil
  def add_message(_thread_id, _message), do: :ok
  def cache_participants(_thread_id, _participants), do: :ok
  def get_participants(_thread_id), do: nil
end