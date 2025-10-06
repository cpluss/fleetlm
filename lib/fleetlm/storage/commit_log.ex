defmodule Fleetlm.Storage.CommitLog do
  @moduledoc """
  File-backed WAL for slot log servers. Not perfect but gets the job done
  without being too complex / burdensome.

  This acts as a staging area for messages before they're persisted to the
  database, in order for us to shortcut the message ack latency by a great
  deal. Being disk IO bound means we can tolerate a lot of throughput without
  affecting the user experience.

  - Entries are stored in fixed-size segment files and framed as
    `<<len::32, crc32::32, payload::binary>>`, where payload is a
    serialized `%Fleetlm.Storage.Entry{}`. Cursors track `{segment, offset}`
    positions so readers can resume without loading entire files into memory.
  - Segments are rotated when they reach the limit, and the current segment is synced to disk
    every 512KB or 25ms.
  - Segments are stored as individual files. This means we can easily drop completed segments
    without loading the entire file into memory.
  - Cursors are persisted alongside the commit log so we can resume from the last flushed position
    after a crash. In the face of a crash we'll resume and potentially double write some messages,
    but that's okay.
  - We use a CRC32 checksum to validate the integrity of the frames, and truncate the segment
    if a CRC mismatch is detected.
  """

  alias Fleetlm.Storage.Entry

  require Logger

  defmodule Cursor do
    @moduledoc "Cursor for the commit log, not to be confused with the database cursor"

    @enforce_keys [:segment, :offset]
    defstruct [:segment, :offset]

    @type t :: %__MODULE__{segment: non_neg_integer(), offset: non_neg_integer()}
  end

  # NOTE: these are not configurable, they're hardcoded to avoid messing up
  # the backwards compatibility of the commit log.
  @frame_header_bytes 8
  # 128kB
  @default_segment_bytes 128 * 1024 * 1024
  # 4kB
  @default_chunk_bytes 4 * 1024 * 1024

  @type t :: %__MODULE__{
          slot: non_neg_integer(),
          dir: String.t(),
          segment_seq: non_neg_integer(),
          segment_path: String.t(),
          writer: IO.device(),
          segment_size: non_neg_integer(),
          segment_limit: pos_integer(),
          # the "tip" of the commit log, one past the last frame
          tip: Cursor.t(),
          bytes_since_sync: non_neg_integer(),
          last_sync_ms: integer()
        }

  @enforce_keys [
    :slot,
    :dir,
    :segment_seq,
    :segment_path,
    :writer,
    :segment_size,
    :segment_limit,
    :tip
  ]
  defstruct [
    :slot,
    :dir,
    :segment_seq,
    :segment_path,
    :writer,
    :segment_size,
    :segment_limit,
    :tip,
    :bytes_since_sync,
    :last_sync_ms
  ]

  @doc """
  Open the commit log for a slot, repairing any partial segments.
  """
  @spec open(non_neg_integer(), keyword()) :: {:ok, t()} | {:error, term()}
  def open(slot, opts \\ []) do
    segment_limit = Keyword.get(opts, :segment_bytes, @default_segment_bytes)
    dir = base_dir()
    :ok = File.mkdir_p(dir)

    with {:ok, segments} <- load_segments(dir, slot),
         {:ok, {seq, path, size}} <- ensure_active_segment(dir, slot, segments),
         {:ok, writer} <- open_writer(path) do
      {:ok,
       %__MODULE__{
         slot: slot,
         dir: dir,
         segment_seq: seq,
         segment_path: path,
         writer: writer,
         segment_size: size,
         segment_limit: segment_limit,
         tip: %Cursor{segment: seq, offset: size},
         bytes_since_sync: 0,
         last_sync_ms: monotonic_ms()
       }}
    end
  end

  @doc """
  Append an entry to the log, returning updated state.
  """
  @spec append(t(), Entry.t()) :: {:ok, t()} | {:error, term()}
  def append(%__MODULE__{} = log, %Entry{} = entry) do
    payload = :erlang.term_to_binary(entry)
    frame = encode_frame(payload)
    frame_size = byte_size(frame)

    with {:ok, log} <- maybe_rotate(log, frame_size),
         :ok <- :file.write(log.writer, frame) do
      new_size = log.segment_size + frame_size

      {:ok,
       %{
         log
         | segment_size: new_size,
           tip: %Cursor{segment: log.segment_seq, offset: new_size},
           bytes_since_sync: log.bytes_since_sync + frame_size
       }}
    else
      {:error, reason} ->
        Logger.error("Failed to append slot #{log.slot} commit log: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Sync the current segment to disk. Resets sync counters on success.
  """
  @spec sync(t()) :: {:ok, t()} | {:error, term()}
  def sync(%__MODULE__{} = log) do
    case :file.datasync(log.writer) do
      :ok ->
        {:ok, %{log | bytes_since_sync: 0, last_sync_ms: monotonic_ms()}}

      {:error, reason} ->
        Logger.error("Failed to fsync commit log #{log.segment_path}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  True when sync thresholds have been exceeded.
  """
  @spec needs_sync?(t(), pos_integer(), pos_integer()) :: boolean()
  def needs_sync?(%__MODULE__{} = log, byte_threshold, interval_ms)
      when byte_threshold > 0 and interval_ms > 0 do
    cond do
      log.bytes_since_sync >= byte_threshold -> true
      monotonic_ms() - log.last_sync_ms >= interval_ms -> true
      true -> false
    end
  end

  @doc """
  Current tip cursor (one past the last frame).
  """
  @spec tip(t()) :: Cursor.t()
  def tip(%__MODULE__{tip: cursor}), do: cursor

  @doc """
  Stream entries between cursors. The callback receives `[Entry.t()]` batches
  plus an accumulator, returning `{:cont, acc}` to continue or `{:halt, acc}`
  to stop early.
  """
  @spec fold(
          non_neg_integer(),
          Cursor.t(),
          Cursor.t(),
          keyword(),
          acc,
          ([Entry.t()], acc -> {:cont, acc} | {:halt, acc})
        ) ::
          {:ok, {Cursor.t(), acc}} | {:error, term()}
        when acc: term()
  def fold(slot, %Cursor{} = from, %Cursor{} = to, opts \\ [], acc, callback) do
    chunk_bytes = Keyword.get(opts, :chunk_bytes, @default_chunk_bytes)

    cond do
      before?(to, from) -> {:error, :invalid_range}
      chunk_bytes < @frame_header_bytes -> {:error, :chunk_too_small}
      true -> do_fold(slot, from, to, chunk_bytes, acc, callback)
    end
  end

  @doc """
  Persist the flushed cursor for crash recovery.

  We store this alongside the commit log so we can resume from the last flushed position
  after a crash. In the face of a crash we'll resume and potentially double write some messages,
  but that's okay.
  """
  @spec persist_cursor(non_neg_integer(), Cursor.t()) :: :ok | {:error, term()}
  def persist_cursor(slot, %Cursor{} = cursor) do
    payload = :erlang.term_to_binary(%{segment: cursor.segment, offset: cursor.offset})
    path = cursor_path(slot)
    tmp = path <> ".tmp"

    with :ok <- File.write(tmp, payload, [:binary]),
         :ok <- File.rename(tmp, path) do
      :ok
    end
  rescue
    error -> {:error, error}
  end

  @doc """
  Load the persisted cursor. Defaults to `{0, 0}`.
  """
  @spec load_cursor(non_neg_integer()) :: {:ok, Cursor.t()} | {:error, term()}
  def load_cursor(slot) do
    case File.read(cursor_path(slot)) do
      {:ok, binary} ->
        case :erlang.binary_to_term(binary, [:safe]) do
          %{segment: segment, offset: offset}
          when is_integer(segment) and is_integer(offset) and segment >= 0 and offset >= 0 ->
            {:ok, %Cursor{segment: segment, offset: offset}}

          %Cursor{} = cursor ->
            {:ok, cursor}

          _other ->
            {:error, :invalid_cursor}
        end

      {:error, :enoent} ->
        {:ok, %Cursor{segment: 0, offset: 0}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    ArgumentError -> {:error, :invalid_cursor}
  end

  @doc """
  Remove fully flushed segments (strictly older than the cursor segment).
  """
  @spec drop_completed_segments(t(), Cursor.t()) :: {:ok, t()}
  def drop_completed_segments(%__MODULE__{} = log, %Cursor{} = cursor) do
    with {:ok, segments} <- load_segments(log.dir, log.slot) do
      segments
      |> Enum.filter(fn {seq, _path, _size} -> seq < cursor.segment end)
      |> Enum.each(fn {_seq, path, _size} ->
        case File.rm(path) do
          :ok ->
            :ok

          {:error, :enoent} ->
            :ok

          {:error, reason} ->
            Logger.warning("Failed to remove commit log segment #{path}: #{inspect(reason)}")
        end
      end)
    end

    {:ok, log}
  end

  @doc """
  Close the writer handle.
  """
  @spec close(t()) :: :ok
  def close(%__MODULE__{writer: writer}) do
    :file.close(writer)
  catch
    :error, :badarg -> :ok
  end

  ## Internal helpers

  # Streaming fold over the commit log between two cursors. Bit of a mess but it works fairly
  # OK. It also means we can avoid loading the entire file into memory, which is a big win
  # when we want to flush massive amounts of messages.
  defp do_fold(_slot, cursor, cursor, _chunk_bytes, acc, _callback), do: {:ok, {cursor, acc}}

  defp do_fold(slot, %Cursor{} = cursor, %Cursor{} = to, chunk_bytes, acc, callback) do
    path = segment_path(slot, cursor.segment)

    case File.stat(path) do
      {:ok, %File.Stat{size: size}} ->
        cond do
          cursor.offset >= size ->
            next = %Cursor{segment: cursor.segment + 1, offset: 0}
            do_fold(slot, next, to, chunk_bytes, acc, callback)

          true ->
            limit_offset = limit_offset(cursor, to, size)

            case :file.open(path, [:raw, :binary, :read, :write]) do
              {:ok, device} ->
                result =
                  try do
                    collect_entries(
                      device,
                      slot,
                      cursor.segment,
                      cursor.offset,
                      limit_offset,
                      chunk_bytes
                    )
                  after
                    :ok = :file.close(device)
                  end

                case result do
                  {:ok, [], new_offset} when new_offset == cursor.offset ->
                    next = %Cursor{segment: cursor.segment + 1, offset: 0}
                    do_fold(slot, next, to, chunk_bytes, acc, callback)

                  {:ok, entries, new_offset} ->
                    new_cursor = %Cursor{segment: cursor.segment, offset: new_offset}

                    case callback.(entries, acc) do
                      {:cont, new_acc} ->
                        do_fold(slot, new_cursor, to, chunk_bytes, new_acc, callback)

                      {:halt, new_acc} ->
                        {:ok, {new_cursor, new_acc}}
                    end

                  {:error, reason} ->
                    {:error, reason}
                end

              {:error, :enoent} ->
                next = %Cursor{segment: cursor.segment + 1, offset: 0}
                do_fold(slot, next, to, chunk_bytes, acc, callback)

              {:error, reason} ->
                {:error, reason}
            end
        end

      {:error, :enoent} ->
        next = %Cursor{segment: cursor.segment + 1, offset: 0}
        do_fold(slot, next, to, chunk_bytes, acc, callback)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp collect_entries(device, slot, segment, offset, limit_offset, chunk_bytes) do
    collect_entries(device, slot, segment, offset, limit_offset, chunk_bytes, [])
  end

  defp collect_entries(_device, _slot, _segment, offset, limit_offset, _chunk_bytes, acc)
       when offset >= limit_offset do
    {:ok, Enum.reverse(acc), offset}
  end

  defp collect_entries(device, slot, segment, offset, limit_offset, chunk_bytes, acc) do
    cond do
      chunk_bytes <= 0 and acc != [] ->
        {:ok, Enum.reverse(acc), offset}

      true ->
        case :file.pread(device, offset, @frame_header_bytes) do
          {:ok, <<len::32, crc::32>>} ->
            frame_bytes = @frame_header_bytes + len
            next_offset = offset + frame_bytes

            cond do
              # safety check to ensure there's no data corruption
              len < 0 ->
                {:error, {:corrupt_frame, slot, segment, offset}}

              next_offset > limit_offset ->
                {:ok, Enum.reverse(acc), offset}

              true ->
                case :file.pread(device, offset + @frame_header_bytes, len) do
                  {:ok, payload} when byte_size(payload) == len ->
                    checksum = :erlang.crc32(payload)

                    if checksum == crc do
                      entry = :erlang.binary_to_term(payload)
                      remaining = chunk_bytes - frame_bytes

                      collect_entries(
                        device,
                        slot,
                        segment,
                        next_offset,
                        limit_offset,
                        remaining,
                        [entry | acc]
                      )
                    else
                      # During normal reads (flush operations), don't truncate on CRC errors.
                      # Just stop reading and return what we have. Truncation should only
                      # happen during initial repair (scan_segment) when the writer is closed.
                      Logger.warning(
                        "Commit log CRC mismatch during read slot=#{slot} segment=#{segment} offset=#{offset}; stopping read"
                      )

                      {:ok, Enum.reverse(acc), offset}
                    end

                  {:ok, _partial} ->
                    {:ok, Enum.reverse(acc), offset}

                  :eof ->
                    {:ok, Enum.reverse(acc), offset}

                  {:error, reason} ->
                    {:error, reason}
                end
            end

          :eof ->
            {:ok, Enum.reverse(acc), offset}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp maybe_rotate(%__MODULE__{} = log, frame_size) do
    if log.segment_size + frame_size <= log.segment_limit do
      {:ok, log}
    else
      next_seq = log.segment_seq + 1

      with {:ok, log} <- sync(log),
           {:ok, writer, path} <- open_new_segment(log.dir, log.slot, next_seq) do
        {:ok,
         %{
           log
           | segment_seq: next_seq,
             segment_path: path,
             writer: writer,
             segment_size: 0,
             tip: %Cursor{segment: next_seq, offset: 0},
             bytes_since_sync: 0
         }}
      end
    end
  end

  defp open_new_segment(dir, slot, seq) do
    path = segment_path(dir, slot, seq)
    :ok = File.write(path, <<>>)

    case open_writer(path) do
      {:ok, writer} -> {:ok, writer, path}
      {:error, reason} -> {:error, reason}
    end
  end

  defp encode_frame(payload) do
    len = byte_size(payload)
    crc = :erlang.crc32(payload)
    <<len::32, crc::32, payload::binary>>
  end

  defp before?(%Cursor{} = a, %Cursor{} = b) do
    cond do
      a.segment < b.segment -> true
      a.segment > b.segment -> false
      true -> a.offset < b.offset
    end
  end

  defp limit_offset(%Cursor{segment: seg}, %Cursor{segment: seg, offset: to_offset}, size) do
    min(to_offset, size)
  end

  defp limit_offset(%Cursor{}, %Cursor{}, size), do: size

  defp load_segments(dir, slot) do
    prefix = "slot_#{slot}_"

    case File.ls(dir) do
      {:ok, entries} ->
        segments =
          entries
          |> Enum.filter(fn name ->
            String.starts_with?(name, prefix) and String.ends_with?(name, ".wal")
          end)
          |> Enum.flat_map(fn name ->
            seq = sequence_from_filename(name)
            path = Path.join(dir, name)

            case repair_segment(path) do
              {:ok, size} ->
                [{seq, path, size}]

              {:error, reason} ->
                Logger.warning(
                  "Failed to repair corrupted segment #{path}: #{inspect(reason)}, removing it"
                )

                File.rm(path)
                []
            end
          end)
          |> Enum.sort_by(fn {seq, _path, _size} -> seq end)

        {:ok, segments}

      {:error, :enoent} ->
        :ok = File.mkdir_p(dir)
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_active_segment(dir, slot, []), do: create_initial_segment(dir, slot)
  defp ensure_active_segment(_dir, _slot, segments), do: {:ok, List.last(segments)}

  defp create_initial_segment(dir, slot) do
    path = segment_path(dir, slot, 0)
    :ok = File.write(path, <<>>)
    {:ok, {0, path, 0}}
  end

  defp repair_segment(path) do
    case :file.open(path, [:raw, :binary, :read, :write]) do
      {:ok, device} ->
        result =
          try do
            scan_segment(device, path, 0)
          after
            :ok = :file.close(device)
          end

        result

      {:error, :enoent} ->
        :ok = File.write(path, <<>>)
        {:ok, 0}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp scan_segment(device, path, offset) do
    case :file.pread(device, offset, @frame_header_bytes) do
      {:ok, <<len::32, crc::32>>} ->
        frame_bytes = @frame_header_bytes + len
        next_offset = offset + frame_bytes

        case :file.pread(device, offset + @frame_header_bytes, len) do
          {:ok, payload} when byte_size(payload) == len ->
            if :erlang.crc32(payload) == crc do
              scan_segment(device, path, next_offset)
            else
              Logger.warning("Repair truncating #{path} at offset #{offset} due to CRC mismatch")
              truncate_file(device, path, offset)
            end

          {:ok, _partial} ->
            Logger.warning("Repair truncating #{path} at offset #{offset} due to partial frame")
            truncate_file(device, path, offset)

          :eof ->
            Logger.warning("Repair truncating #{path} at offset #{offset} due to EOF")
            truncate_file(device, path, offset)

          {:error, reason} ->
            {:error, reason}
        end

      :eof ->
        {:ok, offset}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp truncate_device(device, offset) do
    with {:ok, ^offset} <- :file.position(device, offset),
         :ok <- :file.truncate(device) do
      :ok
    end
  end

  defp truncate_file(device, path, offset) do
    case truncate_device(device, offset) do
      :ok ->
        {:ok, offset}

      {:error, reason} ->
        Logger.error("Failed to truncate #{path} at #{offset}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Utility to ensure we always open the writer in append mode.
  defp open_writer(path) do
    :file.open(path, [:raw, :binary, :append, :write, :delayed_write])
  end

  defp sequence_from_filename(filename) do
    filename
    |> String.trim_leading("slot_")
    |> String.trim_trailing(".wal")
    |> String.split("_")
    |> List.last()
    |> String.to_integer()
  end

  defp segment_path(slot, seq), do: segment_path(base_dir(), slot, seq)

  defp segment_path(dir, slot, seq) do
    Path.join(dir, "slot_#{slot}_#{Integer.to_string(seq) |> String.pad_leading(8, "0")}.wal")
  end

  defp cursor_path(slot), do: Path.join(base_dir(), "slot_#{slot}.cursor")

  defp monotonic_ms do
    System.monotonic_time(:millisecond)
  end

  defp base_dir do
    Application.get_env(
      :fleetlm,
      :slot_log_dir,
      Application.app_dir(:fleetlm, "priv/storage/slot_logs")
    )
  end
end
