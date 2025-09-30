defmodule FleetLM.Storage.SlotLogServer do
  @moduledoc """
  Storage is sharded into slots, each slot is owned by a single process. The slots
  store messages for multiple sessions before they're persisted to the database asynchronously
  in background batches.

  - appends are fast and don't block
  - flushes cause a blocking sync to disk and schedules a background task to send
    the data to the database

  Note that messages in flight aren't persisted in memory but rather to disk in order to
  reduce churn overhead. On larger spikes it ensures memory usage stays consistent at the cost
  of IO latency.
  """

  use GenServer
  require Logger

  alias FleetLM.Storage.{DiskLog, Entry}
  alias FleetLM.Storage.Model.Message
  alias Fleetlm.Repo

  # Configurable but default to 300ms
  @flush_interval_ms Application.compile_env(:fleetlm, :storage_flush_interval_ms, 300)

  def start_link(slot) when is_integer(slot) do
    GenServer.start_link(__MODULE__, slot, name: via(slot))
  end

  @doc """
  Append an entry to the slot's disk_log. Fast operation - just writes to buffer.
  """
  @spec append(non_neg_integer(), Entry.t()) :: :ok | {:error, term()}
  def append(slot, %Entry{} = entry) do
    GenServer.call(via(slot), {:append, entry})
  end

  @doc """
  Read entries from the slot's disk_log.
  """
  @spec read(non_neg_integer(), String.t(), non_neg_integer()) :: {:ok, [Entry.t()]} | {:error, term()}
  def read(slot, session_id, after_seq) do
    GenServer.call(via(slot), {:read, session_id, after_seq})
  end

  @doc """
  Get the disk_log handle for direct access (if needed).
  """
  @spec get_log_handle(non_neg_integer()) :: {:ok, DiskLog.handle()}
  def get_log_handle(slot) do
    GenServer.call(via(slot), :get_log_handle)
  end

  def init(slot) do
    {:ok, log} = DiskLog.open(slot)
    schedule_flush()
    {:ok, %{
      slot: slot,
      log: log,
      dirty: false
    }}
  end

  def handle_call({:append, entry}, _from, state) do
    case DiskLog.append(state.log, entry) do
      :ok ->
        # Record a new append to ensure we trigger a flush
        {:reply, :ok, %{ state | dirty: true }}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:get_log_handle, _from, state) do
    {:reply, {:ok, state.log}, state}
  end

  def handle_info(:flush, %{dirty: true} = state) do
    # Spawn async task to flush - doesn't block appends!
    Task.start(fn -> flush_to_database(state.slot, state.log) end)

    schedule_flush()
    {:noreply, %{ state | dirty: false }}
  end

  def handle_info(:flush, state) do
    # Nothing dirty, just reschedule
    schedule_flush()
    {:noreply, state}
  end

  def terminate(_reason, state) do
    # Ensure we flush the remaining data before we shut down
    case state.dirty do
      true ->
        flush_to_database(state.slot, state.log)
      false ->
        :ok
    end
    DiskLog.close(state.log)
    :ok
  end

  defp via(slot), do: {:global, {:fleetlm_slot_log_server, slot}}

  defp schedule_flush do
    Process.send_after(self(), :flush, @flush_interval_ms)
  end

  defp flush_to_database(slot, log) do
    DiskLog.sync(log)
    case DiskLog.read_all(log) do
      {:error, reason} ->
        Logger.error("Failed to read from disk_log for slot #{slot}: #{inspect(reason)}")
      {:ok, []} ->
        # No entries to flush
        :ok
      {:ok, entries} ->
        messages =
          Enum.map(entries, fn entry ->
            %{
              id: entry.payload.id,
              session_id: entry.payload.session_id,
              sender_id: entry.payload.sender_id,
              recipient_id: entry.payload.recipient_id,
              seq: entry.payload.seq,
              kind: entry.payload.kind,
              content: entry.payload.content,
              metadata: entry.payload.metadata,
              shard_key: entry.payload.shard_key,
              inserted_at: entry.payload.inserted_at
            }
          end)

        case Repo.insert_all(Message, messages, on_conflict: :nothing) do
          {count, _} when is_integer(count) ->
            DiskLog.truncate(log)
          error ->
            Logger.error("Failed to flush slot #{slot} to database: #{inspect(error)}")
        end
    end
  end
end
