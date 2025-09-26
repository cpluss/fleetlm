defmodule Fleetlm.Sessions.Cache do
  @moduledoc false

  alias Cachex

  @tail_cache :fleetlm_session_tails
  @inbox_cache :fleetlm_session_inboxes
  @tail_limit 100

  def tail_cache, do: @tail_cache
  def inbox_cache, do: @inbox_cache

  @spec fetch_tail(String.t(), keyword()) :: {:ok, list()} | :miss | {:error, term()}
  def fetch_tail(session_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, @tail_limit)

    case Cachex.get(@tail_cache, session_id) do
      {:ok, nil} -> :miss
      {:ok, events} when is_list(events) -> {:ok, Enum.take(events, limit)}
      {:ok, _} -> :miss
      {:error, reason} -> {:error, reason}
    end
  end

  @spec put_tail(String.t(), list()) :: :ok | {:error, term()}
  def put_tail(session_id, events) when is_list(events) do
    Cachex.put(@tail_cache, session_id, events)
    |> normalize()
  end

  @spec append_to_tail(String.t(), map(), keyword()) :: :ok | {:error, term()}
  def append_to_tail(session_id, message, opts \\ []) do
    limit = Keyword.get(opts, :limit, @tail_limit)

    case Cachex.get(@tail_cache, session_id) do
      {:ok, nil} -> Cachex.put(@tail_cache, session_id, [message]) |> normalize()
      {:ok, events} when is_list(events) ->
        updated =
          [message | events]
          |> Enum.take(limit)

        Cachex.put(@tail_cache, session_id, updated) |> normalize()

      {:ok, _unexpected} -> Cachex.put(@tail_cache, session_id, [message]) |> normalize()
      {:error, reason} -> {:error, reason}
    end
  end

  @spec delete_tail(String.t()) :: :ok | {:error, term()}
  def delete_tail(session_id) do
    Cachex.del(@tail_cache, session_id) |> normalize()
  end

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
    Cachex.put(@inbox_cache, participant_id, snapshot) |> normalize()
  end

  @spec delete_inbox_snapshot(String.t()) :: :ok | {:error, term()}
  def delete_inbox_snapshot(participant_id) do
    Cachex.del(@inbox_cache, participant_id) |> normalize()
  end

  @spec reset() :: :ok | {:error, term()}
  def reset do
    with :ok <- normalize(Cachex.clear(@tail_cache)),
         :ok <- normalize(Cachex.clear(@inbox_cache)) do
      :ok
    end
  end

  defp normalize(:ok), do: :ok
  defp normalize({:ok, _}), do: :ok
  defp normalize({:error, reason}), do: {:error, reason}
end
