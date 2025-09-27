defmodule Fleetlm.Runtime.Sharding.SlotServer do
  @moduledoc """
  Slot-scoped owner process that represents the shard responsible for a range
  of session ids in the consistent hash ring.

  Each slot server is the single writer for its shard. That keeps ordering and
  durability decisions localized while allowing us to add node-local hot-path
  state (ETS caches, disk logs, idempotency checks) in later phases. Horde keeps
  exactly one slot server per slot alive across the cluster and migrates it when
  hash-ring ownership changes, giving us a distributed load balancer whose fan
  out is the slot count.
  """

  use GenServer, restart: :transient

  alias Fleetlm.Runtime.Sharding.HashRing
  alias Fleetlm.Conversation
  alias Fleetlm.Observability
  alias Fleetlm.Runtime.Persistence.Worker, as: PersistenceWorker
  alias Fleetlm.Runtime.Storage.{DiskLog, Entry, EtsRing, IdempotencyCache}
  alias Ulid

  require Logger

  @ring_limit 64
  @idempotency_ttl_ms :timer.minutes(15)

  defstruct [
    :slot,
    :status,
    :ring_table,
    :idempotency_table,
    :disk_log,
    :persistence_worker,
    seq_tracker: %{}
  ]

  @type status :: :accepting | :draining
  @type state :: %__MODULE__{
          slot: non_neg_integer(),
          status: status(),
          ring_table: :ets.tid(),
          idempotency_table: :ets.tid(),
          disk_log: :disk_log.log(),
          persistence_worker: pid(),
          seq_tracker: %{optional(String.t()) => non_neg_integer()}
        }
  @local_registry Fleetlm.Runtime.Sharding.LocalRegistry

  @spec start_link(non_neg_integer()) :: GenServer.on_start()
  def start_link(slot) when is_integer(slot) and slot >= 0 do
    name = {:via, Registry, {@local_registry, {:shard, slot}}}
    GenServer.start_link(__MODULE__, slot, name: name)
  end

  @spec current_status(GenServer.server()) :: status()
  def current_status(server) do
    GenServer.call(server, :status)
  end

  @spec rebalance(non_neg_integer()) :: :ok
  def rebalance(slot) do
    case Registry.lookup(@local_registry, {:shard, slot}) do
      [{pid, _}] ->
        GenServer.cast(pid, :rebalance)

      [] ->
        :ok
    end
  end

  @spec await_persistence(non_neg_integer(), String.t(), timeout()) :: :ok | {:error, term()}
  def await_persistence(slot, message_id, timeout \\ 5_000) do
    case Registry.lookup(@local_registry, {:shard, slot}) do
      [{pid, _}] ->
        GenServer.call(pid, {:await_persisted, message_id, timeout}, timeout + 100)

      [] ->
        {:error, :noproc}
    end
  end

  @impl true
  def init(slot) do
    Process.flag(:trap_exit, true)

    expected_node = HashRing.owner_node(slot)

    if expected_node != Node.self() do
      Logger.warning(
        "SlotServer #{slot} refused to start; expected owner #{inspect(expected_node)}"
      )

      {:stop, {:wrong_owner, expected_node}}
    else
      with {:ok, disk_log} <- DiskLog.open(slot),
           {:ok, worker} <- PersistenceWorker.start_link(slot: slot) do
        ring_table = EtsRing.new()
        idem_table = IdempotencyCache.new()

        # Replay entries from disk log to restore idempotency cache and sequence tracker
        {restored_seq_tracker, restored_count} = replay_from_disk_log(disk_log, ring_table, idem_table)

        # Monitor the persistence worker
        Process.monitor(worker)

        Logger.debug(
          "Shard #{slot} now accepting traffic on #{inspect(Node.self())} (restored #{restored_count} entries)"
        )

        {:ok,
         %__MODULE__{
           slot: slot,
           status: :accepting,
           ring_table: ring_table,
           idempotency_table: idem_table,
           disk_log: disk_log,
           persistence_worker: worker,
           seq_tracker: restored_seq_tracker
         }}
      else
        {:error, reason} ->
          Logger.error("Shard #{slot} failed to open disk log: #{inspect(reason)}")
          {:stop, {:log_open_failed, reason}}
      end
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, state.status, state}
  end

  @impl true
  def handle_call({:append, session_id, attrs}, _from, state) do
    with :ok <- ensure_owner(state) do
      handle_append(session_id, attrs, state)
    else
      {:handoff, expected} -> handoff_reply(state, expected)
    end
  end

  def handle_call({:replay, session_id, opts}, _from, state) do
    with :ok <- ensure_owner(state) do
      {:reply, Conversation.list_messages(session_id, opts), state}
    else
      {:handoff, expected} -> handoff_reply(state, expected)
    end
  end

  def handle_call({:mark_read, session_id, participant_id, opts}, _from, state) do
    with :ok <- ensure_owner(state) do
      {:reply, Conversation.mark_read(session_id, participant_id, opts), state}
    else
      {:handoff, expected} -> handoff_reply(state, expected)
    end
  end

  def handle_call({:await_persisted, message_id, timeout}, _from, state) do
    if Process.alive?(state.persistence_worker) do
      try do
        case PersistenceWorker.await(state.persistence_worker, message_id, timeout) do
          :ok -> {:reply, :ok, state}
          {:error, :timeout} -> {:reply, {:error, :timeout}, state}
        end
      catch
        :exit, reason ->
          Logger.warning("Persistence worker crashed during await: #{inspect(reason)}")
          {:reply, {:error, :worker_crashed}, restart_persistence_worker(state)}
      end
    else
      Logger.warning("Persistence worker is dead, restarting...")
      new_state = restart_persistence_worker(state)
      {:reply, {:error, :worker_dead}, new_state}
    end
  end

  @impl true
  def handle_cast(:rebalance, %{slot: slot} = state) do
    expected = HashRing.owner_node(slot)

    if expected == Node.self() do
      {:noreply, state}
    else
      Logger.info(
        "Shard #{slot} transitioning to draining on #{inspect(Node.self())}; owner should be #{inspect(expected)}"
      )

      {:stop, {:handoff, expected}, %{state | status: :draining}}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, %{persistence_worker: pid} = state) do
    Logger.warning("Persistence worker #{inspect(pid)} died with reason: #{inspect(reason)}")
    new_state = restart_persistence_worker(state)
    {:noreply, new_state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    # Ignore DOWN messages from other processes
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.error("#{__MODULE__} received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, %{
        slot: slot,
        disk_log: disk_log,
        ring_table: ring,
        idempotency_table: idem,
        persistence_worker: worker
      }) do
    Logger.debug("Shard #{slot} terminating with reason=#{inspect(reason)}")
    if is_pid(worker), do: Process.exit(worker, :shutdown)
    DiskLog.close(disk_log)
    EtsRing.destroy(ring)
    IdempotencyCache.destroy(idem)
    :ok
  end

  defp ensure_owner(%{slot: slot}) do
    expected = HashRing.owner_node(slot)

    if expected == Node.self() do
      :ok
    else
      {:handoff, expected}
    end
  end

  defp handoff_reply(state, expected) do
    Logger.debug("Shard #{state.slot} deferring request; expected owner #{inspect(expected)}")

    {:reply, {:error, :handoff}, %{state | status: :draining}}
  end

  defp handle_append(session_id, attrs, %{idempotency_table: idem_table} = state) do
    {normalized, idem_key} = normalize_attrs(attrs)

    case IdempotencyCache.fetch(idem_table, session_id, idem_key, ttl_ms: @idempotency_ttl_ms) do
      {:hit, %Entry{payload: message}} ->
        {:reply, {:ok, message}, state}

      :miss ->
        perform_append(session_id, normalized, idem_key, state)
    end
  end

  defp perform_append(session_id, attrs, idem_key, state) do
    seq = Map.get(state.seq_tracker, session_id, 0) + 1
    attrs_with_seq = inject_sequence(attrs, seq)

    case Conversation.append_message(session_id, attrs_with_seq) do
      {:ok, message} = ok ->
        entry = Entry.from_message(state.slot, seq, idem_key, message)

        case DiskLog.append(state.disk_log, entry) do
          {:ok, duration_us} ->
            # Safely enqueue to persistence worker, restart if needed
            new_state = safe_enqueue_persistence(state, entry)

            updated_state =
              new_state
              |> maybe_track_seq(session_id, seq)
              |> cache_entry(session_id, idem_key, entry)

            Observability.record_disk_log_append(state.slot, duration_us)

            {:reply, ok, updated_state}

          {:error, reason} ->
            Logger.error("Shard #{state.slot} failed to sync disk log: #{inspect(reason)}")
            {:reply, {:error, {:disk_log_failed, reason}}, state}
        end

      {:error, _reason} = error ->
        {:reply, error, state}
    end
  end

  defp cache_entry(
         %{ring_table: ring, idempotency_table: idem} = state,
         session_id,
         idem_key,
         entry
       ) do
    _ = EtsRing.put(ring, session_id, entry, @ring_limit)
    :ok = IdempotencyCache.put(idem, session_id, idem_key, entry)
    state
  end

  defp maybe_track_seq(state, session_id, seq) do
    %{state | seq_tracker: Map.put(state.seq_tracker, session_id, seq)}
  end

  defp inject_sequence(attrs, seq) do
    metadata = Map.get(attrs, :metadata) || %{}
    merged_metadata = Map.put(metadata, "seq", seq)
    attrs |> Map.put(:metadata, merged_metadata)
  end

  defp restart_persistence_worker(state) do
    # Stop old worker if still alive
    if is_pid(state.persistence_worker) and Process.alive?(state.persistence_worker) do
      Process.exit(state.persistence_worker, :shutdown)
    end

    # Start new worker
    case PersistenceWorker.start_link(slot: state.slot) do
      {:ok, new_worker} ->
        # Monitor the new worker
        Process.monitor(new_worker)
        Logger.info("Restarted persistence worker for slot #{state.slot}")
        %{state | persistence_worker: new_worker}

      {:error, reason} ->
        Logger.error("Failed to restart persistence worker for slot #{state.slot}: #{inspect(reason)}")
        state
    end
  end

  defp safe_enqueue_persistence(state, entry) do
    if Process.alive?(state.persistence_worker) do
      try do
        PersistenceWorker.enqueue(state.persistence_worker, entry)
        state
      catch
        :exit, reason ->
          Logger.warning("Persistence worker died during enqueue: #{inspect(reason)}")
          restart_persistence_worker(state)
      end
    else
      Logger.warning("Persistence worker dead during enqueue, restarting...")
      new_state = restart_persistence_worker(state)

      # Try to enqueue to new worker
      if Process.alive?(new_state.persistence_worker) do
        PersistenceWorker.enqueue(new_state.persistence_worker, entry)
      end

      new_state
    end
  end

  defp replay_from_disk_log(disk_log, ring_table, idem_table) do
    case DiskLog.read_all(disk_log) do
      {:ok, entries} ->
        seq_tracker =
          entries
          |> Enum.reduce(%{}, fn entry, acc ->
            # Restore idempotency cache
            :ok = IdempotencyCache.put(idem_table, entry.session_id, entry.idempotency_key, entry)

            # Restore ETS ring with recent entries (keep only latest @ring_limit entries per session)
            _ = EtsRing.put(ring_table, entry.session_id, entry, @ring_limit)

            # Track highest sequence number per session
            Map.update(acc, entry.session_id, entry.seq, &max(&1, entry.seq))
          end)

        {seq_tracker, length(entries)}

      {:error, reason} ->
        Logger.warning("Failed to read disk log for replay: #{inspect(reason)}")
        {%{}, 0}
    end
  end

  defp normalize_attrs(attrs) when is_map(attrs) do
    allowed = %{
      sender_id: :sender_id,
      kind: :kind,
      content: :content,
      metadata: :metadata,
      idempotency_key: :idempotency_key
    }

    string_allowed = %{
      "sender_id" => :sender_id,
      "kind" => :kind,
      "content" => :content,
      "metadata" => :metadata,
      "idempotency_key" => :idempotency_key
    }

    normalized =
      attrs
      |> Enum.reduce(%{}, fn
        {key, value}, acc when is_atom(key) ->
          case Map.get(allowed, key) do
            nil -> acc
            normalized_key -> Map.put(acc, normalized_key, value)
          end

        {key, value}, acc when is_binary(key) ->
          case Map.get(string_allowed, key) do
            nil -> acc
            normalized_key -> Map.put(acc, normalized_key, value)
          end

        _, acc ->
          acc
      end)
      |> Map.put_new(:kind, "text")
      |> Map.put_new(:content, %{})
      |> Map.put_new(:metadata, %{})

    idem_key =
      normalized
      |> Map.get(:idempotency_key)
      |> case do
        nil -> Ulid.generate()
        value when is_binary(value) -> value
        value -> to_string(value)
      end

    {Map.delete(normalized, :idempotency_key), idem_key}
  end
end
