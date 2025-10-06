defmodule Fleetlm.Storage.SlotLogServer do
  @moduledoc """
  Storage is sharded into slots, each slot is owned by a single process. The slots
  store messages for multiple sessions before they're persisted to the database asynchronously
  in background batches.

  Messages are appended to an on-disk commit log so the write path stays flat
  under load. Flushes stream the WAL into Postgres in batches without loading
  all entries in memory, and completed segments are dropped once persisted.
  """

  use GenServer
  require Logger

  alias Fleetlm.Storage.{CommitLog, Entry}
  alias Fleetlm.Storage.CommitLog.Cursor
  alias Fleetlm.Storage.Model.Message
  alias Fleetlm.Repo

  @default_task_supervisor Fleetlm.Storage.SlotLogTaskSupervisor
  @default_registry Fleetlm.Storage.Registry

  @default_flush_interval_ms Application.compile_env(:fleetlm, :slot_log_flush_interval_ms, 300)
  @flush_timeout Application.compile_env(:fleetlm, :slot_log_flush_timeout, 10_000)

  # 512kB default.
  @default_sync_bytes Application.compile_env(:fleetlm, :slot_log_sync_bytes, 512 * 1024)
  @default_sync_interval_ms Application.compile_env(:fleetlm, :slot_log_sync_interval_ms, 25)
  # 4MB default.
  @default_flush_chunk_bytes Application.compile_env(
                               :fleetlm,
                               :slot_log_flush_chunk_bytes,
                               4 * 1024 * 1024
                             )
  # PostgreSQL has a parameter limit of ~65535. With 10 fields per message,
  # we can safely insert ~6500 messages. Use 5000 for safety margin.
  @insert_batch_size Application.compile_env(:fleetlm, :slot_log_insert_batch_size, 5000)

  @type state :: %{
          slot: non_neg_integer(),
          log: CommitLog.t(),
          dirty: boolean(),
          notify_next_flush: [pid()],
          task_supervisor: Supervisor.name(),
          pending_flush: Task.t() | nil,
          registry: atom() | :global,
          flushed_cursor: Cursor.t(),
          sync_bytes_threshold: pos_integer(),
          sync_interval_ms: pos_integer(),
          flush_chunk_bytes: pos_integer()
        }

  ## Public API

  def start_link(slot) when is_integer(slot) do
    start_link({slot, []})
  end

  def start_link({slot, opts}) when is_integer(slot) and is_list(opts) do
    task_supervisor = Keyword.get(opts, :task_supervisor, @default_task_supervisor)
    registry = Keyword.get(opts, :registry, @default_registry)
    GenServer.start_link(__MODULE__, {slot, task_supervisor, registry}, name: via(slot, registry))
  end

  @doc """
  Append an entry to the slot's commit log.
  """
  @spec append(non_neg_integer(), Entry.t()) :: :ok | {:error, term()}
  def append(slot, %Entry{} = entry) do
    GenServer.call(via(slot), {:append, entry})
  end

  @doc """
  Read entries for a session from the slot's commit log.
  Returns only in-flight (unflushed) entries.
  """
  @spec read(non_neg_integer(), String.t(), non_neg_integer()) ::
          {:ok, [Entry.t()]} | {:error, term()}
  def read(slot, session_id, after_seq) do
    GenServer.call(via(slot), {:read, session_id, after_seq})
  end

  @doc """
  Return the current flushed cursor and pending entries. Primarily for tests.
  """
  @spec snapshot(non_neg_integer()) ::
          {:ok, %{flushed_cursor: Cursor.t(), pending_entries: [Entry.t()]}} | {:error, term()}
  def snapshot(slot) do
    GenServer.call(via(slot), :snapshot)
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
  def init({slot, task_supervisor, registry}) do
    {:ok, log} = CommitLog.open(slot)

    flushed_cursor =
      case CommitLog.load_cursor(slot) do
        {:ok, cursor} ->
          cursor

        {:error, :invalid_cursor} ->
          Logger.warning("Slot #{slot}: Invalid cursor file, starting from beginning")
          %CommitLog.Cursor{segment: 0, offset: 0}

        {:error, reason} ->
          Logger.warning(
            "Slot #{slot}: Failed to load cursor (#{inspect(reason)}), starting from beginning"
          )

          %CommitLog.Cursor{segment: 0, offset: 0}
      end

    tip = CommitLog.tip(log)
    flushed_cursor = clamp_cursor(flushed_cursor, tip)
    dirty? = cursor_before?(flushed_cursor, tip)

    schedule_flush()

    {:ok,
     %{
       slot: slot,
       log: log,
       task_supervisor: task_supervisor,
       registry: registry,
       dirty: dirty?,
       notify_next_flush: [],
       pending_flush: nil,
       flushed_cursor: flushed_cursor,
       sync_bytes_threshold: sync_bytes_threshold(),
       sync_interval_ms: sync_interval_ms(),
       flush_chunk_bytes: flush_chunk_bytes()
     }}
  end

  @impl true
  def handle_call({:append, entry}, _from, state) do
    start = System.monotonic_time()

    case CommitLog.append(state.log, entry) do
      {:ok, log} ->
        log = maybe_sync(log, state.sync_bytes_threshold, state.sync_interval_ms)

        duration_us =
          System.convert_time_unit(System.monotonic_time() - start, :native, :microsecond)

        Fleetlm.Observability.Telemetry.emit_storage_append(
          entry.session_id,
          state.slot,
          :ok,
          duration_us
        )

        {:reply, :ok, %{state | log: log, dirty: true}}

      {:error, reason} ->
        duration_us =
          System.convert_time_unit(System.monotonic_time() - start, :native, :microsecond)

        Fleetlm.Observability.Telemetry.emit_storage_append(
          entry.session_id,
          state.slot,
          :error,
          duration_us
        )

        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:read, session_id, after_seq}, _from, state) do
    # Sync before reading to ensure buffered writes are visible
    {:ok, log} = CommitLog.sync(state.log)
    target = CommitLog.tip(log)

    initial_acc = []

    case CommitLog.fold(
           state.slot,
           state.flushed_cursor,
           target,
           [chunk_bytes: state.flush_chunk_bytes],
           initial_acc,
           fn batch, acc ->
             filtered =
               batch
               |> Enum.filter(fn entry ->
                 entry.session_id == session_id and entry.seq > after_seq
               end)

             {:cont, prepend_batch(filtered, acc)}
           end
         ) do
      {:ok, {_cursor, entries_rev}} ->
        {:reply, {:ok, Enum.reverse(entries_rev)}, %{state | log: log}}

      {:error, reason} ->
        {:reply, {:error, reason}, %{state | log: log}}
    end
  end

  def handle_call(:snapshot, _from, state) do
    # Sync before reading to ensure buffered writes are visible
    {:ok, log} = CommitLog.sync(state.log)
    target = CommitLog.tip(log)

    case CommitLog.fold(
           state.slot,
           state.flushed_cursor,
           target,
           [chunk_bytes: state.flush_chunk_bytes],
           [],
           fn batch, acc ->
             {:cont, prepend_batch(batch, acc)}
           end
         ) do
      {:ok, {_cursor, entries_rev}} ->
        {:reply,
         {:ok,
          %{
            flushed_cursor: state.flushed_cursor,
            pending_entries: Enum.reverse(entries_rev)
          }}, %{state | log: log}}

      {:error, reason} ->
        {:reply, {:error, reason}, %{state | log: log}}
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

    case reply do
      {:error, reason} ->
        {:reply, {:error, reason}, next_state}

      :ok ->
        if next_state.dirty do
          case flush_dirty_now(next_state) do
            {:ok, final_state} -> {:reply, :ok, final_state}
            {:already_clean, final_state} -> {:reply, :ok, final_state}
            {:error, reason, final_state} -> {:reply, {:error, reason}, final_state}
          end
        else
          {:reply, :ok, next_state}
        end
    end
  end

  def handle_call(:flush_now, _from, %{dirty: true, pending_flush: nil} = state) do
    case flush_dirty_now(state) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:already_clean, new_state} -> {:reply, :already_clean, new_state}
      {:error, reason, new_state} -> {:reply, {:error, reason}, new_state}
    end
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

    state =
      if state.dirty do
        case CommitLog.sync(state.log) do
          {:ok, log} ->
            target = CommitLog.tip(log)

            if cursor_before?(state.flushed_cursor, target) do
              case flush_to_database(
                     state.slot,
                     state.flushed_cursor,
                     target,
                     state.flush_chunk_bytes
                   ) do
                {:ok, info} ->
                  {:ok, log} = CommitLog.drop_completed_segments(log, info.flushed_cursor)
                  persist_cursor(state.slot, info.flushed_cursor)

                  %{
                    state
                    | log: log,
                      flushed_cursor: info.flushed_cursor,
                      dirty: cursor_before?(info.flushed_cursor, CommitLog.tip(log)),
                      notify_next_flush: []
                  }

                {:error, _reason} ->
                  %{state | log: log}
              end
            else
              %{state | log: log, dirty: false}
            end

          {:error, _reason} ->
            state
        end
      else
        state
      end

    CommitLog.close(state.log)
    :ok
  end

  ## Internal helpers

  defp via(slot, registry) when is_atom(registry) do
    {:via, Registry, {registry, slot}}
  end

  defp via(slot), do: via(slot, @default_registry)

  defp schedule_flush do
    interval =
      Application.get_env(:fleetlm, :storage_flush_interval_ms, @default_flush_interval_ms)

    Process.send_after(self(), :flush, interval)
  end

  defp maybe_start_async_flush(%{dirty: true, pending_flush: nil} = state) do
    case CommitLog.sync(state.log) do
      {:ok, log} ->
        target = CommitLog.tip(log)

        if cursor_before?(state.flushed_cursor, target) do
          case start_async_flush(state, target) do
            {:ok, task} ->
              %{state | log: log, pending_flush: task}

            {:error, reason} ->
              Logger.error("Slot #{state.slot} failed to start async flush: #{inspect(reason)}")
              %{state | log: log, dirty: true}
          end
        else
          %{state | log: log, dirty: false}
        end

      {:error, reason} ->
        Logger.error("Slot #{state.slot} failed to sync before flush: #{inspect(reason)}")
        state
    end
  end

  defp maybe_start_async_flush(state), do: state

  defp start_async_flush(state, target_cursor) do
    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        flush_to_database(
          state.slot,
          state.flushed_cursor,
          target_cursor,
          state.flush_chunk_bytes
        )
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

  defp handle_flush_completion({:ok, info}, state) do
    apply_flush_success(state, info)
  end

  defp handle_flush_completion({:error, reason}, state) do
    Logger.error("Flush failed for slot #{state.slot}: #{inspect(reason)}")
    {{:error, reason}, %{state | dirty: true}}
  end

  defp apply_flush_success(state, info) do
    Enum.each(state.notify_next_flush, &send(&1, :flushed))

    {:ok, log} = CommitLog.drop_completed_segments(state.log, info.flushed_cursor)
    persist_cursor(state.slot, info.flushed_cursor)

    dirty? = cursor_before?(info.flushed_cursor, CommitLog.tip(log))

    new_state =
      state
      |> Map.put(:notify_next_flush, [])
      |> Map.put(:dirty, dirty?)
      |> Map.put(:flushed_cursor, info.flushed_cursor)
      |> Map.put(:log, log)

    {:ok, new_state}
  end

  defp flush_dirty_now(%{dirty: false} = state), do: {:already_clean, state}

  defp flush_dirty_now(state) do
    case CommitLog.sync(state.log) do
      {:ok, log} ->
        state = %{state | log: log}
        target = CommitLog.tip(log)

        if cursor_before?(state.flushed_cursor, target) do
          case flush_to_database(
                 state.slot,
                 state.flushed_cursor,
                 target,
                 state.flush_chunk_bytes
               ) do
            {:ok, info} ->
              {:ok, new_state} = apply_flush_success(state, info)
              {:ok, new_state}

            {:error, reason} ->
              {:error, reason, state}
          end
        else
          {:already_clean, %{state | dirty: false}}
        end

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp maybe_sync(log, bytes_threshold, interval_ms) do
    if CommitLog.needs_sync?(log, bytes_threshold, interval_ms) do
      case CommitLog.sync(log) do
        {:ok, synced} -> synced
        {:error, _reason} -> log
      end
    else
      log
    end
  end

  defp prepend_batch([], acc), do: acc

  defp prepend_batch(batch, acc) do
    Enum.reduce(batch, acc, fn entry, acc -> [entry | acc] end)
  end

  defp flush_to_database(_slot, %Cursor{} = start, %Cursor{} = target, _chunk)
       when start == target do
    {:ok, %{persisted_count: 0, total_entries: 0, flushed_cursor: target}}
  end

  defp flush_to_database(slot, %Cursor{} = start_cursor, %Cursor{} = target_cursor, chunk_bytes) do
    start_time = System.monotonic_time()

    try do
      initial_acc = %{persisted: 0, total: 0, error: nil}

      result =
        CommitLog.fold(
          slot,
          start_cursor,
          target_cursor,
          [chunk_bytes: chunk_bytes],
          initial_acc,
          fn batch, %{error: nil} = acc ->
            case persist_batch(batch) do
              {:ok, inserted} ->
                {:cont,
                 %{acc | persisted: acc.persisted + inserted, total: acc.total + length(batch)}}

              {:error, reason} ->
                {:halt, %{acc | error: reason}}
            end
          end
        )

      duration_us = microseconds_since(start_time)

      case result do
        {:ok, {cursor, %{error: nil, persisted: persisted, total: total}}} ->
          Fleetlm.Observability.Telemetry.emit_storage_flush(slot, :ok, persisted, duration_us)

          {:ok,
           %{
             persisted_count: persisted,
             total_entries: total,
             flushed_cursor: cursor,
             duration_us: duration_us
           }}

        {:ok, {_cursor, %{error: reason}}} ->
          Fleetlm.Observability.Telemetry.emit_storage_flush(slot, :error, 0, duration_us)
          {:error, reason}

        {:error, reason} ->
          Fleetlm.Observability.Telemetry.emit_storage_flush(slot, :error, 0, duration_us)
          {:error, reason}
      end
    rescue
      error ->
        duration_us = microseconds_since(start_time)

        Fleetlm.Observability.Telemetry.emit_storage_flush(slot, :error, 0, duration_us)
        Logger.error("Flush failed for slot #{slot}: #{inspect(error)}")
        {:error, error}
    catch
      kind, reason ->
        duration_us = microseconds_since(start_time)

        Fleetlm.Observability.Telemetry.emit_storage_flush(slot, :error, 0, duration_us)
        Logger.error("Flush failed for slot #{slot}: #{inspect({kind, reason})}")
        {:error, {kind, reason}}
    end
  end

  defp persist_batch(entries) do
    entries
    |> Enum.map(&entry_to_message_map/1)
    |> Enum.chunk_every(@insert_batch_size)
    |> Enum.reduce_while({:ok, 0}, fn batch, {:ok, acc} ->
      case Repo.insert_all(Message, batch, on_conflict: :nothing) do
        {count, _} when is_integer(count) ->
          {:cont, {:ok, acc + count}}

        other ->
          {:halt, {:error, other}}
      end
    end)
    |> case do
      {:ok, inserted} -> {:ok, inserted}
      {:error, reason} -> {:error, reason}
    end
  end

  defp entry_to_message_map(entry) do
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
  end

  defp cursor_before?(%Cursor{segment: a_seg, offset: a_off}, %Cursor{
         segment: b_seg,
         offset: b_off
       }) do
    cond do
      a_seg < b_seg -> true
      a_seg > b_seg -> false
      true -> a_off < b_off
    end
  end

  defp clamp_cursor(%Cursor{} = cursor, %Cursor{} = tip) do
    if cursor_before?(tip, cursor) do
      tip
    else
      cursor
    end
  end

  defp microseconds_since(start_time) do
    System.convert_time_unit(System.monotonic_time() - start_time, :native, :microsecond)
  end

  defp persist_cursor(slot, %Cursor{} = cursor) do
    case CommitLog.persist_cursor(slot, cursor) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to persist cursor for slot #{slot}: #{inspect(reason)}")
    end
  end

  defp sync_bytes_threshold do
    Application.get_env(:fleetlm, :slot_log_sync_bytes, @default_sync_bytes)
  end

  defp sync_interval_ms do
    Application.get_env(:fleetlm, :slot_log_sync_interval_ms, @default_sync_interval_ms)
  end

  defp flush_chunk_bytes do
    Application.get_env(:fleetlm, :slot_log_flush_chunk_bytes, @default_flush_chunk_bytes)
  end
end
