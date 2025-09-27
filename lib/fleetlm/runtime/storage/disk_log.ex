defmodule Fleetlm.Runtime.Storage.DiskLog do
  @moduledoc """
  Thin wrapper around `:disk_log` that encapsulates the configuration we use for
  per-slot append logs. Each slot owns a writer handle that is opened with
  `:repair` enabled and segment rotation based on bytes written.
  """

  alias Fleetlm.Runtime.Storage.Entry

  @type handle :: :disk_log.log()

  @doc """
  Open (or create) the log file for the given slot.
  Attempts repair if the log is corrupted.
  """
  @spec open(non_neg_integer(), keyword()) :: {:ok, handle()} | {:error, term()}
  def open(slot, opts \\ []) when is_integer(slot) and slot >= 0 do
    base_dir = Keyword.get(opts, :dir, default_base_dir())
    :ok = File.mkdir_p(base_dir)

    path = Keyword.get(opts, :path, path_for(slot, dir: base_dir))
    name = Keyword.get(opts, :name, {:fleetlm_slot_log, slot})

    case :disk_log.open([
           {:name, name},
           {:file, String.to_charlist(path)},
           {:repair, true},
           {:type, :halt}
         ]) do
      {:ok, handle} ->
        {:ok, handle}

      {:repaired, handle, {:recovered, recovered}, {:badbytes, bad_bytes}} ->
        require Logger

        Logger.warning(
          "Disk log for slot #{slot} was corrupted, recovered #{recovered} entries, lost #{bad_bytes} bytes"
        )

        {:ok, handle}

      {:error, {:badarg, _}} ->
        require Logger
        # Try to recover by moving corrupted file and creating new one
        backup_path = "#{path}.corrupt.#{System.system_time(:second)}"

        case File.rename(path, backup_path) do
          :ok ->
            Logger.warning("Moved corrupted log #{path} to #{backup_path}, creating new log")

            :disk_log.open([
              {:name, name},
              {:file, String.to_charlist(path)},
              {:repair, true},
              {:type, :halt}
            ])

          _ ->
            {:error, :log_repair_failed}
        end

      other ->
        other
    end
  end

  @doc """
  Compute the on-disk path for the slot log without opening it.
  """
  @spec path_for(non_neg_integer(), keyword()) :: String.t()
  def path_for(slot, opts \\ []) do
    base_dir = Keyword.get(opts, :dir, default_base_dir())
    Path.join(base_dir, "slot_#{slot}.log")
  end

  @doc """
  Append an entry to the log and force it to disk using `:disk_log.sync/1`.
  Returns the duration in microseconds.
  """
  @spec append(handle(), Entry.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def append(handle, %Entry{} = entry) do
    start = System.monotonic_time()

    with :ok <- safe_log(handle, entry),
         :ok <- safe_sync(handle) do
      duration = System.monotonic_time() - start
      duration_us = System.convert_time_unit(duration, :native, :microsecond)
      {:ok, duration_us}
    else
      {:error, _} = error -> error
      other -> {:error, other}
    end
  end

  defp safe_log(handle, entry) do
    try do
      :disk_log.log(handle, entry)
    catch
      :error, :badarg -> {:error, :no_such_log}
    end
  end

  defp safe_sync(handle) do
    try do
      :disk_log.sync(handle)
    catch
      :error, :badarg -> {:error, :no_such_log}
    end
  end

  @doc """
  Read all entries from the log for recovery purposes.
  Returns entries in chronological order.
  """
  @spec read_all(handle()) :: {:ok, [Entry.t()]} | {:error, term()}
  def read_all(handle) do
    try do
      case :disk_log.chunk(handle, :start) do
        :eof ->
          {:ok, []}

        {continuation, terms} ->
          collect_all_chunks(handle, continuation, terms)

        {:error, _} = error ->
          error
      end
    catch
      :error, :badarg -> {:error, :no_such_log}
    end
  end

  @doc """
  Close the log handle. Safe to call multiple times.
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

  defp collect_all_chunks(handle, continuation, acc) do
    case :disk_log.chunk(handle, continuation) do
      :eof ->
        {:ok, acc}

      {new_continuation, terms} ->
        collect_all_chunks(handle, new_continuation, acc ++ terms)

      {:error, _} = error ->
        error
    end
  end

  defp default_base_dir do
    Application.get_env(:fleetlm, :slot_log_dir, default_priv_path())
  end

  defp default_priv_path do
    Application.app_dir(:fleetlm, "priv/runtime/slot_logs")
  end
end
