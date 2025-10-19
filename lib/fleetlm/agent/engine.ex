defmodule Fleetlm.Agent.Engine do
  @moduledoc """
  Minimal coordination layer for agent webhook delivery.

  Session servers only drop state into ETS via `enqueue/4`. This GenServer polls
  the queue, ensures at most one dispatch per session, and spins up short-lived
  tasks to perform the actual HTTP work. No worker mailboxes, no hidden queues.
  """

  use GenServer
  require Logger

  alias Fleetlm.Agent
  alias Fleetlm.Agent.Dispatch
  alias Fleetlm.Observability.Telemetry, as: ObservabilityTelemetry

  @table :agent_dispatch_queue

  @tick_default Application.compile_env(:fleetlm, :agent_dispatch_tick_ms, 50)
  @window_default Application.compile_env(:fleetlm, :agent_debounce_window_ms, 500)
  @retry_base Application.compile_env(:fleetlm, :agent_dispatch_retry_backoff_ms, 250)
  @retry_max Application.compile_env(:fleetlm, :agent_dispatch_retry_backoff_max_ms, 5_000)
  @attempt_limit_default Application.compile_env(:fleetlm, :agent_dispatch_retry_max_attempts, 5)
  @select_batch 128

  @typedoc "Identifies a session/agent pair"
  @type session_key :: {String.t(), String.t()}

  # Unified ETS schema: {key, user_id, last_sent, target_seq, due_at, first_seq, enqueued_at, attempts, status}
  # status: nil (idle), :pending (queued), :inflight (dispatching)
  #
  # Tuple field positions (1-indexed for :ets.update_element)
  # @_pos_key 1
  @pos_user_id 2
  @pos_last_sent 3
  # @pos_target_seq 4
  @pos_due_at 5
  # @pos_first_seq 6
  # @pos_enqueued_at 7
  # @pos_attempts 8
  @pos_status 9

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Register a user message for outbound delivery.

  The hot path inserts/updates a single ETS table and returns immediately. Multiple
  messages collapse into a single queue entry via `target_seq` and `due_at`.
  """
  @spec enqueue(String.t(), String.t(), String.t(), non_neg_integer()) :: :ok
  def enqueue(session_id, agent_id, user_id, seq)
      when is_binary(session_id) and is_binary(agent_id) and is_binary(user_id) and
             is_integer(seq) do
    if Application.get_env(:fleetlm, :disable_agent_webhooks, false) do
      :ok
    else
      ensure_table()

      key = {agent_id, session_id}
      now = System.monotonic_time(:millisecond)
      due_at = now + debounce_window(agent_id)

      upsert_queue(key, user_id, seq, due_at, now, 0)

      :telemetry.execute(
        [:fleetlm, :agent, :queue, :length],
        %{length: :ets.info(@table, :size)},
        %{agent_id: agent_id}
      )

      :ok
    end
  end

  ## GenServer callbacks

  @impl true
  def init(_opts) do
    ensure_table()
    state = %{poll_ref: nil}
    {:ok, schedule_tick(state)}
  end

  @impl true
  def handle_info(:tick, state) do
    state
    |> dispatch_due_sessions()
    |> schedule_tick()
    |> noreply()
  end

  def handle_info({:dispatch_done, key, info}, state) do
    complete_dispatch(key, info.last_sent)
    record_finish(info, key)

    state
    |> dispatch_due_sessions()
    |> noreply()
  end

  def handle_info({:dispatch_failed, key, reason, meta}, state) do
    attempts = Map.get(meta, :attempts, 1)
    {decision, decision_reason} = decide_retry(reason, attempts)

    case decision do
      :retry ->
        mark_pending(key)
        reschedule_with_backoff(key, meta)
        log_dispatch_failure(:retry, key, reason, attempts, decision_reason, meta)

      :drop ->
        drop_dispatch(key, meta)
        log_dispatch_failure(:drop, key, reason, attempts, decision_reason, meta)
    end

    state
    |> dispatch_due_sessions()
    |> noreply()
  end

  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    # Task crashed - the task supervisor will log this, we just continue
    # with the next dispatch as that will retry the task.
    Logger.debug("Agent dispatch task terminated: #{inspect(reason)}")
    {:noreply, dispatch_due_sessions(state)}
  end

  defp noreply(state), do: {:noreply, state}

  ## Queue handling --------------------------------------------------------------

  defp dispatch_due_sessions(state) do
    now = System.monotonic_time(:millisecond)
    dispatch_from_select(state, :ets.select(@table, queue_match_spec(now), @select_batch))
  end

  defp dispatch_from_select(state, :"$end_of_table"), do: state

  defp dispatch_from_select(state, {entries, continuation}) do
    state = Enum.reduce(entries, state, &maybe_start_dispatch/2)
    dispatch_from_select(state, :ets.select(continuation))
  end

  defp maybe_start_dispatch(entry, state) do
    {key, user_id, _last_sent, target_seq, _due_at, first_seq, enqueued_at, attempts, status} =
      entry

    if status == :inflight do
      # Already dispatching; push due_at forward to avoid re-reading
      :ets.update_element(
        @table,
        key,
        {@pos_due_at, System.monotonic_time(:millisecond) + tick_ms()}
      )

      state
    else
      launch_dispatch(key, user_id, target_seq, first_seq, enqueued_at, attempts, state)
    end
  end

  defp launch_dispatch(key, user_id, target_seq, first_seq, enqueued_at, attempts, state) do
    {agent_id, session_id} = key
    last_sent = lookup_last_sent(key, target_seq)
    scheduler = self()
    started_at = System.monotonic_time(:millisecond)

    # Mark as inflight in ETS
    :ets.update_element(@table, key, [{@pos_status, :inflight}])

    job = %{
      agent_id: agent_id,
      session_id: session_id,
      user_id: user_id,
      last_sent: last_sent,
      target_seq: target_seq,
      first_seq: first_seq,
      enqueued_at: enqueued_at,
      started_at: started_at,
      attempts: attempts
    }

    task = fn ->
      case Dispatch.run(job) do
        {:ok, result} ->
          send(scheduler, {:dispatch_done, key, Map.put(result, :last_sent, target_seq)})
          :ok

        {:error, reason} ->
          send(scheduler, {:dispatch_failed, key, reason, Map.put(job, :attempts, attempts + 1)})
          {:error, reason}
      end
    end

    case Task.Supervisor.start_child(Fleetlm.Agent.Engine.TaskSupervisor, task) do
      {:ok, _pid} ->
        state

      {:error, reason} ->
        Logger.error("Failed to start agent dispatch task",
          session_key: key,
          reason: inspect(reason)
        )

        mark_pending(key)
        reschedule_with_backoff(key, Map.put(job, :attempts, attempts + 1))
        state
    end
  end

  defp complete_dispatch(key, new_last_sent) do
    # Update last_sent and clear dispatch fields
    case :ets.lookup(@table, key) do
      [
        {^key, user_id, _old_last_sent, target_seq, due_at, first_seq, enqueued_at, _attempts,
         _status}
      ] ->
        if is_nil(target_seq) or target_seq <= new_last_sent do
          :ets.insert(@table, {key, user_id, new_last_sent, nil, nil, nil, nil, 0, nil})
        else
          {agent_id, _session_id} = key
          now = System.monotonic_time(:millisecond)

          next_first_seq =
            case first_seq do
              nil -> new_last_sent + 1
              value -> max(value, new_last_sent + 1)
            end

          next_due_at = due_at || now + debounce_window(agent_id)
          next_enqueued_at = enqueued_at || now

          :ets.insert(@table, {
            key,
            user_id,
            new_last_sent,
            target_seq,
            next_due_at,
            next_first_seq,
            next_enqueued_at,
            0,
            :pending
          })
        end

      [] ->
        :ok
    end
  end

  defp mark_pending(key) do
    :ets.update_element(@table, key, [{@pos_status, :pending}])
  end

  defp drop_dispatch(key, meta) do
    case :ets.lookup(@table, key) do
      [
        {^key, user_id, last_sent, _target_seq, _due_at, _first_seq, _enqueued_at, _attempts,
         _status}
      ] ->
        # Reset entry to the neutral "idle" state (mirrors complete_dispatch/2). We keep the row
        # so future enqueues retain the last_sent watermark and don't re-send old messages.
        :ets.insert(@table, {
          key,
          user_id || Map.get(meta, :user_id),
          last_sent,
          nil,
          nil,
          nil,
          nil,
          0,
          nil
        })

      [] ->
        :ok
    end
  end

  defp reschedule_with_backoff(key, %{agent_id: agent_id, session_id: session_id} = meta) do
    ensure_table()

    attempts = max(Map.get(meta, :attempts, 1), 1)
    backoff_ms = backoff_ms(attempts)

    user_id = meta.user_id || lookup_user_id(key)
    last_sent = Map.get(meta, :last_sent, lookup_last_sent(key, 0))
    target_seq = Map.get(meta, :target_seq, last_sent + 1)
    due_at = System.monotonic_time(:millisecond) + backoff_ms
    enqueued_at = System.monotonic_time(:millisecond)

    upsert_queue(key, user_id, target_seq, due_at, enqueued_at, attempts)

    :telemetry.execute(
      [:fleetlm, :agent, :dispatch, :retry],
      %{backoff_ms: backoff_ms},
      %{agent_id: agent_id, session_id: session_id}
    )
  end

  ## ETS helpers

  # Unified table schema: {key, user_id, last_sent, target_seq, due_at, first_seq, enqueued_at, attempts, status}
  defp upsert_queue(key, user_id, seq, due_at, enqueued_at, attempts) do
    case :ets.lookup(@table, key) do
      [] ->
        # New entry: initialize with last_sent = seq - 1
        last_sent = max(seq - 1, 0)

        :ets.insert(
          @table,
          {key, user_id, last_sent, seq, due_at, seq, enqueued_at, attempts, :pending}
        )

      [
        {^key, existing_user, last_sent, current_seq, _due, first_seq, _enqueued,
         current_attempts, status}
      ]
      when not is_nil(current_seq) ->
        # Existing queue entry: update target_seq and due_at, preserve first_seq
        next_status =
          case status do
            :inflight -> :inflight
            _ -> :pending
          end

        :ets.insert(@table, {
          key,
          existing_user || user_id,
          last_sent,
          max(seq, current_seq),
          due_at,
          first_seq,
          enqueued_at,
          max(attempts, current_attempts),
          next_status
        })

      [
        {^key, existing_user, last_sent, _nil_seq, _nil_due, _nil_first, _nil_enqueued,
         _zero_attempts, _nil_status}
      ] ->
        # Idle entry: start new dispatch
        :ets.insert(@table, {
          key,
          existing_user || user_id,
          last_sent,
          seq,
          due_at,
          seq,
          enqueued_at,
          attempts,
          :pending
        })
    end
  end

  defp lookup_last_sent(key, fallback) do
    :ets.lookup_element(@table, key, @pos_last_sent)
  rescue
    ArgumentError -> max(fallback - 1, 0)
  end

  defp lookup_user_id(key) do
    :ets.lookup_element(@table, key, @pos_user_id)
  rescue
    ArgumentError -> nil
  end

  defp ensure_table do
    ensure_table_exists(@table, [:set, :public, :named_table, {:write_concurrency, true}])
  end

  defp ensure_table_exists(name, options) do
    case :ets.whereis(name) do
      :undefined ->
        try do
          :ets.new(name, options)
        rescue
          ArgumentError ->
            # Another process beat us to table creation.
            :ok
        end

      _ ->
        :ok
    end
  end

  defp record_finish(
         %{
           duration_ms: duration_ms,
           message_count: count,
           started_at: started,
           enqueued_at: enqueued
         },
         key
       )
       when is_integer(duration_ms) do
    {agent_id, session_id} = key
    queue_wait = max(started - enqueued, 0)

    :telemetry.execute(
      [:fleetlm, :agent, :dispatch, :finish],
      %{queue_wait_ms: queue_wait, duration_ms: duration_ms},
      %{agent_id: agent_id, session_id: session_id, message_count: count}
    )
  end

  defp record_finish(_, _), do: :ok

  defp queue_match_spec(now) do
    # Match entries where due_at <= now and status is :pending (not :inflight)
    [
      {{:"$1", :"$2", :"$3", :"$4", :"$5", :"$6", :"$7", :"$8", :"$9"},
       [{:"=<", :"$5", now}, {:"/=", :"$9", :inflight}],
       [{{:"$1", :"$2", :"$3", :"$4", :"$5", :"$6", :"$7", :"$8", :"$9"}}]}
    ]
  end

  defp debounce_window(agent_id) do
    global_default = Application.get_env(:fleetlm, :agent_debounce_window_ms, @window_default)

    case Agent.Cache.get(agent_id) do
      {:ok, %{debounce_window_ms: window}} when is_integer(window) -> window
      _ -> global_default
    end
  end

  defp backoff_ms(attempt) do
    trunc(min(@retry_base * :math.pow(2, attempt - 1), @retry_max))
  end

  defp max_attempts do
    attempts =
      Application.get_env(:fleetlm, :agent_dispatch_retry_max_attempts, @attempt_limit_default)

    if is_integer(attempts) and attempts > 0 do
      attempts
    else
      @attempt_limit_default
    end
  end

  @doc false
  @spec decide_retry(term(), term()) :: {:retry | :drop, term()}
  def decide_retry(reason, attempts) do
    attempt_count =
      case attempts do
        n when is_integer(n) and n >= 0 -> n
        _ -> 0
      end

    case reason do
      {:http_error, status} ->
        case retry_strategy_for_status(status) do
          :retry -> attempts_decision(attempt_count)
          :drop -> {:drop, {:http_status, status}}
        end

      :agent_disabled ->
        {:drop, :agent_disabled}

      {:json_decode_failed, _} ->
        {:drop, :invalid_payload}

      :invalid_message_format ->
        {:drop, :invalid_message_format}

      {:invalid_message_format, _} ->
        {:drop, :invalid_message_format}

      _ ->
        attempts_decision(attempt_count)
    end
  end

  defp attempts_decision(attempt_count) do
    if attempt_count >= max_attempts() do
      {:drop, :max_attempts}
    else
      {:retry, :backoff}
    end
  end

  @doc false
  @spec retry_strategy_for_status(term()) :: :retry | :drop
  def retry_strategy_for_status(status) when is_integer(status) do
    cond do
      status in [502, 503] ->
        :retry

      status == 404 ->
        :drop

      status >= 500 and status < 600 ->
        :drop

      status >= 400 and status < 500 ->
        :drop

      true ->
        :retry
    end
  end

  def retry_strategy_for_status(_status), do: :retry

  defp log_dispatch_failure(:retry, key, reason, attempts, decision_reason, _meta) do
    Logger.warning(
      "Agent dispatch failed; retry scheduled (attempt #{attempts}): #{inspect(reason)}",
      session_key: key,
      attempts: attempts,
      decision_reason: decision_reason
    )
  end

  defp log_dispatch_failure(:drop, key, reason, attempts, decision_reason, meta) do
    Logger.error("Agent dispatch dropped after #{attempts} attempts: #{inspect(reason)}",
      session_key: key,
      attempts: attempts,
      decision_reason: decision_reason,
      agent_id: Map.get(meta, :agent_id),
      session_id: Map.get(meta, :session_id)
    )

    agent_id = Map.get(meta, :agent_id)
    session_id = Map.get(meta, :session_id)

    if is_binary(agent_id) and is_binary(session_id) do
      ObservabilityTelemetry.emit_agent_dispatch_drop(
        agent_id,
        session_id,
        decision_reason,
        reason
      )
    end
  end

  defp schedule_tick(%{poll_ref: ref} = state) do
    if ref, do: Process.cancel_timer(ref)
    %{state | poll_ref: Process.send_after(self(), :tick, tick_ms())}
  end

  defp tick_ms do
    Application.get_env(:fleetlm, :agent_dispatch_tick_ms, @tick_default)
  end
end
