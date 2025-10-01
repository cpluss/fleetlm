defmodule FleetLM.Storage.SlotLogServer do
  @moduledoc """
  Storage is sharded into slots, each slot is owned by a single process. The slots
  store messages for multiple sessions before they're persisted to the database asynchronously
  in background batches.

  - appends are fast and don't block
  - flushes happen off the GenServer mailbox via a supervised task so heavy
    database work never blocks incoming appends
  - callers can synchronously wait for a flush when needed (eg. tests, drains)

  Messages in flight are written to disk to keep memory flat during spikes. If a flush
  crashes we keep the slot marked dirty and try again on the next interval to avoid
  silently dropping data.
  """

  use GenServer
  require Logger

  alias FleetLM.Storage.{DiskLog, Entry}
  alias FleetLM.Storage.Model.Message
  alias Fleetlm.Repo

  @default_task_supervisor FleetLM.Storage.SlotLogTaskSupervisor

  @flush_interval_ms Application.compile_env(:fleetlm, :storage_flush_interval_ms, 300)
  @flush_timeout Application.compile_env(:fleetlm, :slot_flush_timeout, 10_000)

  @type state :: %{
          slot: non_neg_integer(),
          log: DiskLog.handle(),
          dirty: boolean(),
          notify_next_flush: [pid()],
          task_supervisor: Supervisor.name(),
          pending_flush: Task.t() | nil
        }

  ## Public API

  def start_link(slot) when is_integer(slot) do
    start_link({slot, []})
  end

  def start_link({slot, opts}) when is_integer(slot) and is_list(opts) do
    task_supervisor = Keyword.get(opts, :task_supervisor, @default_task_supervisor)
    GenServer.start_link(__MODULE__, {slot, task_supervisor}, name: via(slot))
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
  @spec read(non_neg_integer(), String.t(), non_neg_integer()) ::
          {:ok, [Entry.t()]} | {:error, term()}
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
  Notify the caller when the next flush finishes. Used heavily by tests.
  """
  @spec notify_next_flush(non_neg_integer()) :: :ok
  def notify_next_flush(slot) do
    GenServer.call(via(slot), :notify_next_flush)
  end

  @doc """
  Force a flush and wait for completion. Returns :ok on success, :already_clean when
  nothing needed flushing, or {:error, reason} when the flush failed.
  """
  @spec flush_now(non_neg_integer()) :: :ok | :already_clean | {:error, term()}
  def flush_now(slot) do
    GenServer.call(via(slot), :flush_now, @flush_timeout + 5_000)
  end

  ## GenServer callbacks

  @impl true
  def init({slot, task_supervisor}) do
    {:ok, log} = DiskLog.open(slot)
    schedule_flush()

    {:ok,
     %{
       slot: slot,
       log: log,
       task_supervisor: task_supervisor,
       dirty: false,
       notify_next_flush: [],
       pending_flush: nil
     }}
  end

  @impl true
  def handle_call({:append, entry}, _from, state) do
    case DiskLog.append(state.log, entry) do
      :ok ->
        {:reply, :ok, %{state | dirty: true}}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:read, session_id, after_seq}, _from, state) do
    case DiskLog.read_all(state.log) do
      {:ok, entries} ->
        filtered =
          entries
          |> Enum.filter(fn entry ->
            entry.session_id == session_id and entry.seq > after_seq
          end)
          |> Enum.sort_by(& &1.seq)

        {:reply, {:ok, filtered}, state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:notify_next_flush, {from, _ref}, state) do
    {:reply, :ok, %{state | notify_next_flush: [from | state.notify_next_flush]}}
  end

  @impl true
  def handle_call(:flush_now, _from, %{dirty: false, pending_flush: nil} = state) do
    {:reply, :already_clean, state}
  end

  def handle_call(:flush_now, _from, %{pending_flush: %Task{} = task} = state) do
    result = await_flush_task(task, @flush_timeout)
    {reply, next_state} = handle_flush_completion(result, %{state | pending_flush: nil})
    {:reply, reply, next_state}
  end

  def handle_call(:flush_now, _from, %{dirty: true, pending_flush: nil} = state) do
    result = flush_to_database(state.slot, state.log)
    {reply, next_state} = handle_flush_completion(result, %{state | dirty: true})
    {:reply, reply, next_state}
  end

  @impl true
  def handle_call(:get_log_handle, _from, state) do
    {:reply, {:ok, state.log}, state}
  end

  @impl true
  def handle_info(:flush, state) do
    new_state = maybe_start_async_flush(state)
    schedule_flush()
    {:noreply, new_state}
  end

  def handle_info({ref, result}, %{pending_flush: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {_, new_state} = handle_flush_completion(result, %{state | pending_flush: nil})
    {:noreply, new_state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{pending_flush: %Task{ref: ref}} = state) do
    Logger.error("Slot #{state.slot} flush task crashed: #{inspect(reason)}")
    {:noreply, %{state | pending_flush: nil, dirty: true}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    state =
      case state.pending_flush do
        %Task{} = task ->
          case Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill) do
            {:ok, result} ->
              {_, new_state} = handle_flush_completion(result, %{state | pending_flush: nil})
              new_state

            _ ->
              %{state | pending_flush: nil, dirty: true}
          end

        _ ->
          state
      end

    if state.dirty do
      case flush_to_database(state.slot, state.log) do
        {:ok, _info} ->
          Enum.each(state.notify_next_flush, &send(&1, :flushed))

        {:error, reason} ->
          Logger.error("Failed to flush slot #{state.slot} during terminate: #{inspect(reason)}")
      end
    end

    DiskLog.close(state.log)
    :ok
  end

  ## Internal helpers

  defp via(slot), do: {:global, {:fleetlm_slot_log_server, slot}}

  defp schedule_flush do
    Process.send_after(self(), :flush, @flush_interval_ms)
  end

  defp maybe_start_async_flush(%{dirty: true, pending_flush: nil} = state) do
    case start_async_flush(state) do
      {:ok, task} ->
        %{state | dirty: false, pending_flush: task}

      {:error, reason} ->
        Logger.error("Failed to start flush task for slot #{state.slot}: #{inspect(reason)}")
        %{state | dirty: true}
    end
  end

  defp maybe_start_async_flush(state), do: state

  defp start_async_flush(state) do
    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        flush_to_database(state.slot, state.log)
      end)

    {:ok, task}
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp await_flush_task(%Task{} = task, timeout) do
    Task.await(task, timeout)
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp handle_flush_completion({:ok, _info}, state) do
    Enum.each(state.notify_next_flush, &send(&1, :flushed))

    new_state = %{state | notify_next_flush: [], dirty: false}
    {:ok, new_state}
  end

  defp handle_flush_completion({:error, reason}, state) do
    Logger.error("Flush failed for slot #{state.slot}: #{inspect(reason)}")
    {{:error, reason}, %{state | dirty: true}}
  end

  defp flush_to_database(slot, log) do
    with :ok <- DiskLog.sync(log),
         {:ok, entries} <- DiskLog.read_all(log) do
      persist_entries(slot, log, entries)
    end
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp persist_entries(_slot, _log, []), do: {:ok, :noop}

  defp persist_entries(slot, log, entries) do
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
        :ok = DiskLog.truncate(log)
        {:ok, {:persisted, count}}

      other ->
        {:error, {slot, other}}
    end
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
