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

  @type state :: %{
    slot: non_neg_integer(),
    log: DiskLog.handle(),
    dirty: boolean(),
    notify_next_flush: [GenServer.from()]
  }

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

  @doc """
  Notify the callee on the next flush, used for eg. testing purposes
  when we want to test out the flush mechanism.
  """
  @spec notify_next_flush(non_neg_integer()) :: :ok
  def notify_next_flush(slot) do
    GenServer.call(via(slot), :notify_next_flush)
  end

  @spec init(non_neg_integer()) :: {:ok, state()}
  def init(slot) do
    {:ok, log} = DiskLog.open(slot)
    schedule_flush()
    {:ok, %{
      slot: slot,
      log: log,
      dirty: false,
      notify_next_flush: []
    }}
  end

  def handle_call({:append, entry}, _from, state) do
    case DiskLog.append(state.log, entry) do
      :ok ->
        # Record a new append to ensure we trigger a flush
        Logger.debug("SlotLogServer[#{state.slot}]: Appended entry, setting dirty to true")
        {:reply, :ok, %{ state | dirty: true }}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:notify_next_flush, {from, _ref}, state) do
    {:reply, :ok, %{state | notify_next_flush: [from | state.notify_next_flush]}}
  end

  def handle_call(:get_log_handle, _from, state) do
    {:reply, {:ok, state.log}, state}
  end

  def handle_info(:flush, %{dirty: true} = state) do
    Logger.debug("SlotLogServer[#{state.slot}]: Flushing dirty data, #{length(state.notify_next_flush)} waiters")
    # Spawn async task to flush - doesn't block appends!
    Task.start(fn -> flush_to_database(state) end)

    schedule_flush()
    {:noreply, %{state | dirty: false, notify_next_flush: []}}
  end

  def handle_info(:flush, state) do
    Logger.debug("SlotLogServer[#{state.slot}]: Flush skipped (not dirty), #{length(state.notify_next_flush)} waiters queued")
    # Nothing dirty, just reschedule
    schedule_flush()
    {:noreply, state}
  end

  def terminate(reason, state) do
    Logger.debug("SlotLogServer[#{state.slot}]: Terminating (reason: #{inspect(reason)}), dirty: #{state.dirty}")
    # Ensure we flush the remaining data before we shut down
    case state.dirty do
      true ->
        Logger.debug("SlotLogServer[#{state.slot}]: Flushing dirty data during termination")
        flush_to_database(state)
      false ->
        Logger.debug("SlotLogServer[#{state.slot}]: No dirty data to flush during termination")
        :ok
    end
    DiskLog.close(state.log)
    :ok
  end

  defp via(slot), do: {:global, {:fleetlm_slot_log_server, slot}}

  defp schedule_flush do
    Process.send_after(self(), :flush, @flush_interval_ms)
  end

  defp flush_to_database(%{slot: slot, log: log, notify_next_flush: notify_next_flush}) do
    Logger.debug("SlotLogServer[#{slot}]: flush_to_database started")
    DiskLog.sync(log)
    case DiskLog.read_all(log) do
      {:error, reason} ->
        Logger.error("Failed to read from disk_log for slot #{slot}: #{inspect(reason)}")
      {:ok, []} ->
        Logger.debug("SlotLogServer[#{slot}]: No entries to flush, notifying #{length(notify_next_flush)} waiters")
        # No entries to flush, but still notify waiters
        Enum.each(notify_next_flush, fn from ->
          send(from, :flushed)
        end)
      {:ok, entries} ->
        Logger.debug("SlotLogServer[#{slot}]: Flushing #{length(entries)} entries to database")
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
            Logger.debug("SlotLogServer[#{slot}]: Inserted #{count} messages, notifying #{length(notify_next_flush)} waiters")
            DiskLog.truncate(log)
            Enum.each(notify_next_flush, fn from ->
              send(from, :flushed)
            end)
          error ->
            Logger.error("Failed to flush slot #{slot} to database: #{inspect(error)}")
        end
    end
  end
end
