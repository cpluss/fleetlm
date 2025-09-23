defmodule Fleetlm.Chat.Cache do
  @moduledoc false

  alias Cachex
  alias Fleetlm.Chat.Events

  @dm_tails_cache :fleetlm_dm_tails
  @inbox_cache :fleetlm_inbox_snapshots
  @read_cursors_cache :fleetlm_read_cursors

  @default_tail_limit 100

  def dm_tails_cache, do: @dm_tails_cache
  def inbox_cache, do: @inbox_cache
  def read_cursors_cache, do: @read_cursors_cache

  ## Conversation tails

  @spec fetch_tail(String.t(), keyword()) ::
          {:ok, [Events.DmMessage.t()]} | :miss | {:error, term()}
  def fetch_tail(dm_key, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_tail_limit)

    case Cachex.get(@dm_tails_cache, dm_key) do
      {:ok, nil} -> :miss
      {:ok, events} when is_list(events) -> {:ok, Enum.take(events, limit)}
      {:ok, _unexpected} -> :miss
      {:error, reason} -> {:error, reason}
    end
  end

  @spec put_tail(String.t(), [Events.DmMessage.t()]) :: :ok | {:error, term()}
  def put_tail(dm_key, events) when is_list(events) do
    Cachex.put(@dm_tails_cache, dm_key, events)
    |> normalize_result()
  end

  @spec append_to_tail(String.t(), Events.DmMessage.t(), keyword()) :: :ok | {:error, term()}
  def append_to_tail(dm_key, %Events.DmMessage{} = event, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_tail_limit)

    case Cachex.get(@dm_tails_cache, dm_key) do
      {:ok, nil} ->
        Cachex.put(@dm_tails_cache, dm_key, [event])
        |> normalize_result()

      {:ok, events} when is_list(events) ->
        updated =
          [event | events]
          |> Enum.take(limit)

        Cachex.put(@dm_tails_cache, dm_key, updated)
        |> normalize_result()

      {:ok, _unexpected} ->
        Cachex.put(@dm_tails_cache, dm_key, [event])
        |> normalize_result()

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec delete_tail(String.t()) :: :ok | {:error, term()}
  def delete_tail(dm_key) do
    Cachex.del(@dm_tails_cache, dm_key)
    |> normalize_result()
  end

  ## Inbox snapshots

  @spec fetch_inbox_snapshot(String.t()) :: {:ok, any()} | :miss | {:error, term()}
  def fetch_inbox_snapshot(participant_id) do
    case Cachex.get(@inbox_cache, participant_id) do
      {:ok, nil} -> :miss
      {:ok, snapshot} -> {:ok, snapshot}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec put_inbox_snapshot(String.t(), any()) :: :ok | {:error, term()}
  def put_inbox_snapshot(participant_id, snapshot) do
    Cachex.put(@inbox_cache, participant_id, snapshot)
    |> normalize_result()
  end

  @spec delete_inbox_snapshot(String.t()) :: :ok | {:error, term()}
  def delete_inbox_snapshot(participant_id) do
    Cachex.del(@inbox_cache, participant_id)
    |> normalize_result()
  end

  ## Read cursors

  @spec fetch_read_cursor(String.t(), String.t()) :: {:ok, any()} | :miss | {:error, term()}
  def fetch_read_cursor(dm_key, participant_id) do
    key = {dm_key, participant_id}

    case Cachex.get(@read_cursors_cache, key) do
      {:ok, nil} -> :miss
      {:ok, cursor} -> {:ok, cursor}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec put_read_cursor(String.t(), String.t(), any()) :: :ok | {:error, term()}
  def put_read_cursor(dm_key, participant_id, cursor) do
    Cachex.put(@read_cursors_cache, {dm_key, participant_id}, cursor)
    |> normalize_result()
  end

  @spec delete_read_cursor(String.t(), String.t()) :: :ok | {:error, term()}
  def delete_read_cursor(dm_key, participant_id) do
    Cachex.del(@read_cursors_cache, {dm_key, participant_id})
    |> normalize_result()
  end

  @spec reset() :: :ok | {:error, term()}
  def reset do
    with :ok <- normalize_result(Cachex.clear(@dm_tails_cache)),
         :ok <- normalize_result(Cachex.clear(@inbox_cache)),
         :ok <- normalize_result(Cachex.clear(@read_cursors_cache)) do
      :ok
    end
  end

  defp normalize_result(:ok), do: :ok
  defp normalize_result({:ok, _value}), do: :ok
  defp normalize_result({:error, _reason} = error), do: error
end
