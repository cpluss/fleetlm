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
  """
  @spec open(non_neg_integer(), keyword()) :: {:ok, handle()} | {:error, term()}
  def open(slot, opts \\ []) when is_integer(slot) and slot >= 0 do
    base_dir = Keyword.get(opts, :dir, default_base_dir())
    :ok = File.mkdir_p(base_dir)

    path = Keyword.get(opts, :path, path_for(slot, dir: base_dir))
    name = Keyword.get(opts, :name, {:fleetlm_slot_log, slot})

    :disk_log.open([
      {:name, name},
      {:file, String.to_charlist(path)},
      {:repair, true},
      {:type, :halt}
    ])
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

    with :ok <- :disk_log.log(handle, entry),
         :ok <- :disk_log.sync(handle) do
      duration = System.monotonic_time() - start
      duration_us = System.convert_time_unit(duration, :native, :microsecond)
      {:ok, duration_us}
    else
      {:error, _} = error -> error
      other -> {:error, other}
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

  defp default_base_dir do
    Application.get_env(:fleetlm, :slot_log_dir, default_priv_path())
  end

  defp default_priv_path do
    Application.app_dir(:fleetlm, "priv/runtime/slot_logs")
  end
end
