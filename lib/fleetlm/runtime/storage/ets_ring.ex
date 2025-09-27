defmodule Fleetlm.Runtime.Storage.EtsRing do
  @moduledoc """
  Lightweight per-slot ETS ring buffer that keeps the most recent messages for
  each active session. The slot server owns the table and serialises all
  mutations, keeping the implementation simple while still offering O(1)
  append/lookups and cheap eviction.
  """

  alias Fleetlm.Runtime.Storage.Entry

  @type table :: :ets.tid()

  @doc """
  Create a new ring table. The caller is responsible for destroying the table
  when the slot server terminates.
  """
  @spec new(keyword()) :: table()
  def new(_opts \\ []) do
    :ets.new(__MODULE__, [
      :set,
      :private,
      {:read_concurrency, true},
      {:write_concurrency, false}
    ])
  end

  @doc """
  Append an entry to the session ring, keeping only the newest `limit` items.
  Returns the updated slice.
  """
  @spec put(table(), String.t(), Entry.t(), pos_integer()) :: [Entry.t()]
  def put(table, session_id, %Entry{} = entry, limit) when is_integer(limit) and limit > 0 do
    current =
      case :ets.lookup(table, session_id) do
        [] -> []
        [{^session_id, entries}] when is_list(entries) -> entries
        [{^session_id, _unexpected}] -> []
      end

    updated =
      [entry | current]
      |> Enum.take(limit)

    true = :ets.insert(table, {session_id, updated})
    updated
  end

  @doc """
  Fetch the cached slice for the session. Returns an empty list if the session
  hasn't produced any entries on this slot.
  """
  @spec list(table(), String.t()) :: [Entry.t()]
  def list(table, session_id) do
    case :ets.lookup(table, session_id) do
      [{^session_id, entries}] when is_list(entries) -> entries
      _ -> []
    end
  end

  @doc """
  Remove the table and free ETS resources. This is safe to call multiple times.
  """
  @spec destroy(table()) :: :ok
  def destroy(table) do
    :ets.delete(table)
    :ok
  catch
    :error, :badarg -> :ok
  end
end
