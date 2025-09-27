defmodule Fleetlm.Runtime.Storage.IdempotencyCache do
  @moduledoc """
  Slot-local ETS-backed idempotency cache keyed by `{session_id, idempotency_key}`.

  The cache keeps a bounded amount of recent append acknowledgements so the
  shard can return the original response if a client retries an already-acked
  request. Entries expire lazily based on a wall-clock TTL; eviction is handled
  opportunistically on reads/writes to keep the implementation lightweight.
  """

  alias Fleetlm.Runtime.Storage.Entry

  @type table :: :ets.tid()

  @doc """
  Create the ETS table that stores idempotency entries.
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
  Look up a prior append by its session/idempotency key pair.
  """
  @spec fetch(table(), String.t(), String.t(), keyword()) :: {:hit, Entry.t()} | :miss
  def fetch(table, session_id, key, opts \\ []) do
    ttl_ms = Keyword.get(opts, :ttl_ms, :timer.minutes(15))
    now = monotonic_ms()

    case :ets.lookup(table, {session_id, key}) do
      [{{^session_id, ^key}, %{entry: %Entry{} = entry, inserted_at: inserted_at}}] ->
        if now - inserted_at <= ttl_ms do
          {:hit, entry}
        else
          :ets.delete(table, {session_id, key})
          :miss
        end

      _ ->
        :miss
    end
  end

  @doc """
  Store or refresh an idempotency entry.
  """
  @spec put(table(), String.t(), String.t(), Entry.t()) :: :ok
  def put(table, session_id, key, %Entry{} = entry) do
    true = :ets.insert(table, {{session_id, key}, %{entry: entry, inserted_at: monotonic_ms()}})
    :ok
  end

  @doc """
  Remove the table and free ETS resources.
  """
  @spec destroy(table()) :: :ok
  def destroy(table) do
    :ets.delete(table)
    :ok
  catch
    :error, :badarg -> :ok
  end

  defp monotonic_ms do
    System.monotonic_time() |> System.convert_time_unit(:native, :millisecond)
  end
end
