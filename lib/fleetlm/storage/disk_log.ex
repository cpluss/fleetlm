defmodule Fleetlm.Storage.DiskLog do
  @moduledoc """
  Utility functions for working with disk_log as a write-ahead log.

  This module provides helpers for opening, appending, and reading from
  disk_log files. The disk_log itself is a GenServer that handles concurrent
  access, so multiple processes can safely append to the same log.

  The disk log serves as a WAL to decouple write latency from database
  performance. Messages are written to disk first, then asynchronously
  persisted to the database by a separate worker process.
  """

  require Logger

  alias Fleetlm.Storage.Entry

  @cursor_version 1

  @type handle :: :disk_log.log()

  @doc """
  Open a disk log for the given slot. Creates the log if it doesn't exist,
  repairs it if corrupted. Returns the log handle.
  """
  @spec open(non_neg_integer()) :: {:ok, handle()} | {:error, term()}
  def open(slot) when is_integer(slot) do
    :ok = ensure_base_dir()

    path = log_path(slot)
    name = {:fleetlm_slot_log, slot}

    case :disk_log.open([
           {:name, name},
           {:file, String.to_charlist(path)},
           {:repair, true},
           {:type, :halt}
         ]) do
      {:ok, handle} ->
        {:ok, handle}

      {:repaired, handle, {:recovered, recovered}, {:badbytes, bad_bytes}} ->
        Logger.warning(
          "Disk log for slot #{slot} was corrupted, recovered #{recovered} entries, lost #{bad_bytes} bytes"
        )

        Fleetlm.Observability.Telemetry.emit_storage_recovery(
          slot,
          :corruption,
          recovered,
          bad_bytes
        )

        {:ok, handle}

      {:error, {:not_a_log_file, _path}} ->
        # File is completely corrupted beyond repair - delete and recreate
        Logger.warning(
          "Disk log for slot #{slot} is not a valid log file, recreating from scratch"
        )

        # Critical: complete data loss for this slot
        Fleetlm.Observability.Telemetry.emit_storage_recovery(
          slot,
          :not_a_log_file,
          0,
          0
        )

        File.rm(path)

        case :disk_log.open([
               {:name, name},
               {:file, String.to_charlist(path)},
               {:repair, false},
               {:type, :halt}
             ]) do
          {:ok, handle} ->
            {:ok, handle}

          {:error, _} = error ->
            # Repair failed - slot is dead
            Fleetlm.Observability.Telemetry.emit_storage_recovery(
              slot,
              :repair_failed,
              0,
              0
            )

            error
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Append an entry to the disk log. Just buffers the write - use sync/1 to
  force fsync to disk.
  """
  @spec append(handle(), Entry.t()) :: :ok | {:error, term()}
  def append(handle, %Entry{} = entry) do
    :disk_log.log(handle, entry)
  end

  @doc """
  Force sync to disk. Ensures all buffered writes are persisted.
  """
  @spec sync(handle()) :: :ok | {:error, term()}
  def sync(handle) do
    :disk_log.sync(handle)
  end

  @doc """
  Read all entries from the log using chunked reads.
  """
  @spec read_all(handle()) :: {:ok, [Entry.t()]} | {:error, term()}
  def read_all(handle) do
    try do
      case :disk_log.chunk(handle, :start) do
        :eof ->
          {:ok, []}

        {continuation, terms} when is_list(terms) ->
          collect_chunks(handle, continuation, Enum.reverse(terms))

        {:error, _} = error ->
          error
      end
    catch
      :error, :badarg -> {:error, :no_such_log}
    end
  end

  @doc """
  Truncate the log, removing all entries.
  """
  @spec truncate(handle()) :: :ok | {:error, term()}
  def truncate(handle) do
    :disk_log.truncate(handle)
  end

  @doc """
  Rewrite the log with the provided entries.

  This helper is used by retention logic that wants to drop the oldest items
  while keeping the newest tail in order. The operation is atomic with respect
  to the owning process because the GenServer serialises access to the handle.
  """
  @spec rewrite(handle(), [Entry.t()]) :: :ok | {:error, term()}
  def rewrite(handle, entries) when is_list(entries) do
    with :ok <- :disk_log.truncate(handle) do
      Enum.reduce_while(entries, :ok, fn entry, :ok ->
        case :disk_log.log(handle, entry) do
          :ok -> {:cont, :ok}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end
  end

  @doc """
  Persist the flushed cursor for the given slot to disk.
  """
  @spec persist_cursor(non_neg_integer(), non_neg_integer()) :: :ok | {:error, term()}
  def persist_cursor(slot, flushed_count) when is_integer(flushed_count) and flushed_count >= 0 do
    :ok = ensure_base_dir()

    payload =
      :erlang.term_to_binary(%{
        version: @cursor_version,
        flushed_count: flushed_count
      })

    path = cursor_path(slot)
    temp_path = path <> ".tmp"

    with :ok <- File.write(temp_path, payload, [:binary]),
         :ok <- File.rename(temp_path, path) do
      :ok
    end
  end

  @doc """
  Load the flushed cursor from disk. Missing cursors default to zero.
  """
  @spec load_cursor(non_neg_integer()) :: {:ok, non_neg_integer()} | {:error, term()}
  def load_cursor(slot) do
    path = cursor_path(slot)

    case File.read(path) do
      {:ok, binary} ->
        decode_cursor(binary)

      {:error, :enoent} ->
        {:ok, 0}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Close the log handle.
  """
  @spec close(handle()) :: :ok
  def close(handle) do
    case :disk_log.close(handle) do
      :ok -> :ok
      {:error, :no_such_log} -> :ok
      other -> other
    end
  catch
    :error, :badarg -> :ok
  end

  ## Private Functions

  defp collect_chunks(handle, continuation, acc) do
    case :disk_log.chunk(handle, continuation) do
      :eof ->
        {:ok, Enum.reverse(acc)}

      {new_continuation, terms} when is_list(terms) ->
        reduced = Enum.reduce(terms, acc, fn term, acc -> [term | acc] end)
        collect_chunks(handle, new_continuation, reduced)

      {:error, _} = error ->
        error
    end
  end

  defp decode_cursor(binary) do
    case :erlang.binary_to_term(binary, [:safe]) do
      %{version: @cursor_version, flushed_count: count} when is_integer(count) and count >= 0 ->
        {:ok, count}

      count when is_integer(count) and count >= 0 ->
        {:ok, count}

      other ->
        {:error, {:invalid_cursor, other}}
    end
  rescue
    ArgumentError -> {:error, :invalid_cursor_format}
  end

  defp log_path(slot), do: Path.join(base_dir(), "slot_#{slot}.log")
  defp cursor_path(slot), do: Path.join(base_dir(), "slot_#{slot}.cursor")

  defp base_dir do
    Application.get_env(
      :fleetlm,
      :slot_log_dir,
      Application.app_dir(:fleetlm, "priv/storage/slot_logs")
    )
  end

  defp ensure_base_dir do
    File.mkdir_p(base_dir())
  end
end
