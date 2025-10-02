defmodule Fleetlm.Storage.SlotLogServer do
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

  alias Fleetlm.Storage.{DiskLog, Entry}
  alias Fleetlm.Storage.Model.Message
  alias Fleetlm.Repo

  @default_task_supervisor Fleetlm.Storage.SlotLogTaskSupervisor
  @default_registry Fleetlm.Storage.Registry

  @default_flush_interval_ms 300
  @flush_timeout Application.compile_env(:fleetlm, :slot_flush_timeout, 10_000)

  @default_retention_bytes 128 * 1024 * 1024
  @default_retention_target 0.75

  @type state :: %{
          slot: non_neg_integer(),
          log: DiskLog.handle(),
          dirty: boolean(),
          notify_next_flush: [pid()],
          task_supervisor: Supervisor.name(),
          pending_flush: Task.t() | nil,
          registry: atom() | :global,
          flushed_count: non_neg_integer(),
          retention_bytes: pos_integer() | :infinity,
          retention_target: float()
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
  def init({slot, task_supervisor, registry}) do
    {:ok, log} = DiskLog.open(slot)
    {retention_bytes, retention_target} = retention_config()

    {dirty?, flushed_count} =
      case DiskLog.read_all(log) do
        {:ok, entries} ->
          entry_count = length(entries)

          case DiskLog.load_cursor(slot) do
            {:ok, cursor} ->
              clamped = min(entry_count, cursor)

              if cursor > entry_count do
                Logger.warning(
                  "Slot #{slot} cursor #{cursor} exceeds entry count #{entry_count}; clamping to #{clamped}"
                )
              end

              {entry_count > clamped, clamped}

            {:error, reason} ->
              Logger.warning(
                "Slot #{slot} failed to load cursor: #{inspect(reason)}. " <>
                  "Defaulting flushed count to 0."
              )

              {entry_count > 0, 0}
          end

        {:error, reason} ->
          Logger.warning(
            "Slot #{slot} failed to read existing log on init: #{inspect(reason)}. " <>
              "Marking dirty to trigger recovery flush."
          )

          {true, 0}
      end

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
       flushed_count: flushed_count,
       retention_bytes: retention_bytes,
       retention_target: retention_target
     }}
  end

  @impl true
  def handle_call({:append, entry}, _from, state) do
    start = System.monotonic_time()

    case DiskLog.append(state.log, entry) do
      :ok ->
        duration_us =
          System.convert_time_unit(System.monotonic_time() - start, :native, :microsecond)

        Fleetlm.Observability.Telemetry.emit_storage_append(
          entry.session_id,
          state.slot,
          :ok,
          duration_us
        )

        {:reply, :ok, %{state | dirty: true}}

      {:error, _} = error ->
        duration_us =
          System.convert_time_unit(System.monotonic_time() - start, :native, :microsecond)

        Fleetlm.Observability.Telemetry.emit_storage_append(
          entry.session_id,
          state.slot,
          :error,
          duration_us
        )

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
    result = flush_to_database(state.slot, state.log, state.flushed_count)
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
      case flush_to_database(state.slot, state.log, state.flushed_count) do
        {:ok, info} ->
          Enum.each(state.notify_next_flush, &send(&1, :flushed))

          updated =
            state
            |> Map.put(:notify_next_flush, [])
            |> Map.put(:dirty, false)
            |> Map.put(:flushed_count, info.flushed_count)
            |> maybe_compact_log()

          _ = persist_cursor_state(updated)

        {:error, reason} ->
          Logger.error("Failed to flush slot #{state.slot} during terminate: #{inspect(reason)}")
      end
    end

    DiskLog.close(state.log)
    :ok
  end

  ## Internal helpers

  defp via(slot) do
    via(slot, @default_registry)
  end

  defp via(slot, :global), do: {:global, {:fleetlm_slot_log_server, slot}}

  defp via(slot, registry) when is_atom(registry) do
    {:via, Registry, {registry, slot}}
  end

  defp schedule_flush do
    interval =
      Application.get_env(:fleetlm, :storage_flush_interval_ms, @default_flush_interval_ms)

    Process.send_after(self(), :flush, interval)
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
        flush_to_database(state.slot, state.log, state.flushed_count)
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
    Enum.each(state.notify_next_flush, &send(&1, :flushed))

    state_after_flush =
      state
      |> Map.put(:notify_next_flush, [])
      |> Map.put(:dirty, false)
      |> Map.put(:flushed_count, info.flushed_count)

    new_state =
      state_after_flush
      |> maybe_compact_log()
      |> persist_cursor_state()

    {:ok, new_state}
  end

  defp handle_flush_completion({:error, reason}, state) do
    log_flush_error(state.slot, reason)
    {{:error, reason}, %{state | dirty: true}}
  end

  defp flush_to_database(slot, log, flushed_count) do
    start = System.monotonic_time()

    try do
      result =
        with :ok <- DiskLog.sync(log),
             {:ok, entries} <- DiskLog.read_all(log),
             {:ok, persist_info} <- persist_new_entries(slot, entries, flushed_count) do
          {:ok,
           %{
             persisted_count: persist_info.count,
             total_entries: length(entries),
             flushed_count: persist_info.flushed_count
           }}
        end

      duration_us =
        System.convert_time_unit(System.monotonic_time() - start, :native, :microsecond)

      case result do
        {:ok, info} ->
          Fleetlm.Observability.Telemetry.emit_storage_flush(
            slot,
            :ok,
            info.persisted_count,
            duration_us
          )

          {:ok, info}

        {:error, reason} = error ->
          Fleetlm.Observability.Telemetry.emit_storage_flush(slot, :error, 0, duration_us)
          Logger.error("Flush failed for slot #{slot}: #{inspect(reason)}")
          error
      end
    rescue
      error ->
        duration_us =
          System.convert_time_unit(System.monotonic_time() - start, :native, :microsecond)

        Fleetlm.Observability.Telemetry.emit_storage_flush(slot, :error, 0, duration_us)
        Logger.error("Flush failed for slot #{slot}: #{inspect(error)}")
        {:error, error}
    catch
      kind, reason ->
        duration_us =
          System.convert_time_unit(System.monotonic_time() - start, :native, :microsecond)

        Fleetlm.Observability.Telemetry.emit_storage_flush(slot, :error, 0, duration_us)
        Logger.error("Flush failed for slot #{slot}: #{inspect({kind, reason})}")
        {:error, {kind, reason}}
    end
  end

  defp persist_new_entries(slot, entries, flushed_count) do
    total_entries = length(entries)
    to_persist = Enum.drop(entries, flushed_count)

    case to_persist do
      [] ->
        {:ok, %{count: 0, flushed_count: total_entries}}

      _ ->
        messages =
          Enum.map(to_persist, fn entry ->
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
            {:ok, %{count: count, flushed_count: total_entries}}

          other ->
            {:error, {slot, other}}
        end
    end
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp maybe_compact_log(%{retention_bytes: :infinity} = state), do: state

  defp maybe_compact_log(%{retention_bytes: bytes} = state) when bytes <= 0, do: state

  defp maybe_compact_log(%{flushed_count: 0} = state), do: state

  defp maybe_compact_log(state) do
    with {:ok, entries} <- DiskLog.read_all(state.log) do
      {entries_with_bytes, total_bytes} = entries_with_sizes(entries)

      if total_bytes <= state.retention_bytes do
        state
      else
        target_bytes = retention_target_bytes(state.retention_bytes, state.retention_target)

        {kept_entries, dropped_count, dropped_bytes} =
          drop_persisted(entries_with_bytes, state.flushed_count, target_bytes)

        cond do
          dropped_count == 0 ->
            state

          true ->
            case DiskLog.rewrite(state.log, kept_entries) do
              :ok ->
                Logger.debug(
                  "Compacted slot #{state.slot} log: dropped #{dropped_count} entries (#{dropped_bytes} bytes)"
                )

                new_flushed_count =
                  state.flushed_count
                  |> Kernel.-(dropped_count)
                  |> max(0)
                  |> min(length(kept_entries))

                %{state | flushed_count: new_flushed_count}

              {:error, reason} ->
                Logger.error(
                  "Failed to rewrite slot #{state.slot} log during compaction: #{inspect(reason)}"
                )

                state
            end
        end
      end
    else
      {:error, reason} ->
        Logger.error("Failed to read slot #{state.slot} log for compaction: #{inspect(reason)}")
        state
    end
  end

  defp persist_cursor_state(state) do
    case DiskLog.persist_cursor(state.slot, state.flushed_count) do
      :ok ->
        state

      {:error, reason} ->
        Logger.error("Failed to persist cursor for slot #{state.slot}: #{inspect(reason)}")
        state
    end
  end

  defp drop_persisted(entries_with_sizes, flushed_count, target_bytes) do
    initial_bytes = total_bytes(entries_with_sizes)

    {kept_rev, dropped_count, dropped_bytes, _current_bytes, _index} =
      Enum.reduce(entries_with_sizes, {[], 0, 0, initial_bytes, 0}, fn {entry, size},
                                                                       {acc, drop_count,
                                                                        drop_bytes, current_bytes,
                                                                        index} ->
        cond do
          index < flushed_count and current_bytes > target_bytes ->
            {acc, drop_count + 1, drop_bytes + size, current_bytes - size, index + 1}

          true ->
            {[entry | acc], drop_count, drop_bytes, current_bytes, index + 1}
        end
      end)

    {Enum.reverse(kept_rev), dropped_count, dropped_bytes}
  end

  defp total_bytes(entries_with_sizes) do
    Enum.reduce(entries_with_sizes, 0, fn {_entry, size}, acc -> acc + size end)
  end

  defp entries_with_sizes(entries) do
    Enum.map_reduce(entries, 0, fn entry, acc ->
      size = :erlang.external_size(entry)
      {{entry, size}, acc + size}
    end)
  end

  defp retention_target_bytes(:infinity, _target), do: :infinity

  defp retention_target_bytes(bytes, target) do
    ratio = clamp_retention_target(target)

    candidate =
      bytes
      |> Kernel.*(ratio)
      |> Float.floor()
      |> trunc()

    cond do
      candidate <= 0 -> bytes
      candidate > bytes -> bytes
      true -> candidate
    end
  end

  defp retention_config do
    bytes =
      case Application.get_env(:fleetlm, :slot_log_max_bytes) do
        :infinity ->
          :infinity

        nil ->
          @default_retention_bytes

        value when is_integer(value) and value > 0 ->
          value

        other ->
          Logger.warning(
            "Invalid :slot_log_max_bytes configuration #{inspect(other)}; falling back to #{@default_retention_bytes}"
          )

          @default_retention_bytes
      end

    target =
      case Application.get_env(:fleetlm, :slot_log_compact_target) do
        nil ->
          @default_retention_target

        value when is_integer(value) ->
          clamp_retention_target(value / 1)

        value when is_float(value) ->
          clamp_retention_target(value)

        other ->
          Logger.warning(
            "Invalid :slot_log_compact_target configuration #{inspect(other)}; falling back to #{@default_retention_target}"
          )

          @default_retention_target
      end

    {bytes, target}
  end

  defp clamp_retention_target(value) when is_number(value) do
    value
    |> max(0.0)
    |> min(1.0)
  end

  defp log_flush_error(_slot, _reason) do
    # Errors are now handled via telemetry in flush_to_database
    :ok
  end
end
