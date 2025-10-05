defmodule Fleetlm.Agent.Debouncer do
  @moduledoc """
  Debounces agent webhook dispatches to batch rapid message bursts.

  Instead of dispatching a webhook for every message, we:
  1. Track when messages arrive with a timer
  2. Reset timer on each new message (debounce)
  3. Dispatch webhook when timer fires
  4. Emit telemetry for time-to-webhook and batch size

  Uses ETS for deduplication - only the latest message sequence matters.

  ## Metrics Captured
  - Time to webhook (debounce delay)
  - Batch size (messages accumulated during debounce window)
  """

  use GenServer
  require Logger

  alias Fleetlm.Observability.Telemetry

  @table_name :agent_debounce_queue

  defmodule Entry do
    @moduledoc false
    defstruct [
      :session_id,
      :agent_id,
      :user_id,
      :seq,
      :timer_ref,
      :scheduled_at,
      :first_message_seq
    ]

    @type t :: %__MODULE__{
            session_id: String.t(),
            agent_id: String.t(),
            user_id: String.t(),
            seq: non_neg_integer(),
            timer_ref: reference(),
            scheduled_at: integer(),
            first_message_seq: non_neg_integer()
          }
  end

  ## Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Schedule an agent webhook dispatch with debouncing.

  If a dispatch is already scheduled for this session, cancels it and reschedules.
  Tracks the first message sequence to calculate batch size on dispatch.
  """
  @spec schedule(String.t(), String.t(), String.t(), non_neg_integer(), non_neg_integer()) :: :ok
  def schedule(session_id, agent_id, user_id, seq, window_ms)
      when is_binary(session_id) and is_binary(agent_id) and is_binary(user_id) and
             is_integer(seq) and is_integer(window_ms) do
    GenServer.cast(__MODULE__, {:schedule, session_id, agent_id, user_id, seq, window_ms})
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    # Create ETS table for debounce queue
    table =
      :ets.new(@table_name, [
        :set,
        :public,
        :named_table,
        {:keypos, 1},
        {:read_concurrency, true}
      ])

    Logger.info("Agent.Debouncer started with ETS table #{inspect(table)}")
    {:ok, %{table: table}}
  end

  @impl true
  def handle_cast({:schedule, session_id, agent_id, user_id, seq, window_ms}, state) do
    now = System.monotonic_time(:millisecond)

    # Check if there's an existing entry
    existing_entry =
      case :ets.lookup(@table_name, session_id) do
        [{^session_id, entry}] -> entry
        [] -> nil
      end

    # Cancel existing timer if present
    if existing_entry do
      Process.cancel_timer(existing_entry.timer_ref)
    end

    # Determine first_message_seq (for batch size calculation)
    first_message_seq =
      if existing_entry do
        existing_entry.first_message_seq
      else
        seq
      end

    # Schedule new timer
    timer_ref = Process.send_after(self(), {:dispatch, session_id}, window_ms)

    # Create new entry
    entry = %Entry{
      session_id: session_id,
      agent_id: agent_id,
      user_id: user_id,
      seq: seq,
      timer_ref: timer_ref,
      scheduled_at: now,
      first_message_seq: first_message_seq
    }

    # Store in ETS
    :ets.insert(@table_name, {session_id, entry})

    {:noreply, state}
  end

  @impl true
  def handle_info({:dispatch, session_id}, state) do
    # Lookup and remove entry atomically
    case :ets.take(@table_name, session_id) do
      [{^session_id, entry}] ->
        dispatch_webhook(entry)

      [] ->
        # Already processed or cancelled
        Logger.debug("Debounce dispatch for session #{session_id} already processed")
    end

    {:noreply, state}
  end

  ## Private Helpers

  defp dispatch_webhook(entry) do
    now = System.monotonic_time(:millisecond)
    debounce_delay_ms = now - entry.scheduled_at
    debounce_delay_us = debounce_delay_ms * 1000

    # Calculate batch size
    batched_messages = entry.seq - entry.first_message_seq + 1

    # Get debounce window from agent or use config default
    window_ms =
      case Fleetlm.Agent.Cache.get(entry.agent_id) do
        {:ok, agent} -> agent.debounce_window_ms
        {:error, _} -> Application.get_env(:fleetlm, :agent_debounce_window_ms, 500)
      end

    # Emit debounce telemetry (time-to-webhook metric)
    Telemetry.emit_agent_debounce(
      entry.agent_id,
      entry.session_id,
      debounce_delay_us,
      batched_messages,
      window_ms
    )

    # Dispatch to webhook worker pool
    Fleetlm.Agent.Dispatcher.dispatch_async(
      entry.session_id,
      entry.agent_id,
      entry.user_id
    )

    Logger.debug("Debounced agent dispatch",
      session_id: entry.session_id,
      agent_id: entry.agent_id,
      debounce_delay_ms: debounce_delay_ms,
      batched_messages: batched_messages
    )
  end
end
