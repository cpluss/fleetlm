defmodule FleetLM.Storage.DiskLog do
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

  alias FleetLM.Storage.Entry

  @type handle :: :disk_log.log()

  @doc """
  Open a disk log for the given slot. Creates the log if it doesn't exist,
  repairs it if corrupted. Returns the log handle.
  """
  @spec open(non_neg_integer()) :: {:ok, handle()} | {:error, term()}
  def open(slot) when is_integer(slot) do
    base_dir =
      Application.get_env(
        :fleetlm,
        :slot_log_dir,
        Application.app_dir(:fleetlm, "priv/storage/slot_logs")
      )

    :ok = File.mkdir_p(base_dir)

    path = Path.join(base_dir, "slot_#{slot}.log")
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

        {:ok, handle}

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
          collect_chunks(handle, continuation, terms)

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
        {:ok, acc}

      {new_continuation, terms} when is_list(terms) ->
        collect_chunks(handle, new_continuation, acc ++ terms)

      {:error, _} = error ->
        error
    end
  end
end
