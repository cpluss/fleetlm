defmodule Fleetlm.Chat.ConversationServer do
  @moduledoc """
  We maintain a per-conversation server that is responsible for serialising direct messages and emitting
  domain events. This allows us to scale the number of conversations we can support by having a single
  process per conversation. The servers are aggressively recycled after a period of inactivity.
  """

  use GenServer, restart: :transient

  alias Fleetlm.Chat.{DmKey, Event, Events, InboxServer, Storage}
  alias Fleetlm.Telemetry.RuntimeCounters

  @tail_limit 100
  @registry Fleetlm.Chat.ConversationRegistry
  @idle_timeout Application.compile_env(:fleetlm, :conversation_idle_ms, 180_000)

  ## Public API

  @spec via(String.t()) :: {:via, Registry, {module(), String.t()}}
  def via(dm_key), do: {:via, Registry, {@registry, dm_key}}

  @spec start_link(String.t()) :: GenServer.on_start()
  def start_link(dm_key) when is_binary(dm_key) do
    GenServer.start_link(__MODULE__, dm_key, name: via(dm_key))
  end

  @spec send_message(String.t(), String.t(), String.t(), String.t() | nil, map()) ::
          {:ok, Event.DmMessage.t()} | {:error, term()}
  def send_message(dm_key, sender_id, recipient_id, text, metadata) do
    GenServer.call(via(dm_key), {:send_message, sender_id, recipient_id, text, metadata})
  end

  @spec heartbeat(String.t()) :: :ok
  def heartbeat(dm_key) do
    GenServer.cast(via(dm_key), :heartbeat)
  end

  @spec ensure_open(String.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, %{dm_key: String.t(), initial_message: Event.DmMessage.t() | nil}}
          | {:error, term()}
  def ensure_open(dm_key, initiator_id, other_participant_id, initial_text) do
    GenServer.call(via(dm_key), {:ensure_open, initiator_id, other_participant_id, initial_text})
  end

  @spec history(String.t(), keyword()) :: [Event.DmMessage.t()]
  def history(dm_key, opts \\ []) do
    GenServer.call(via(dm_key), {:history, opts})
  end

  ## GenServer callbacks

  @impl true
  def init(dm_key) do
    dm = DmKey.parse!(dm_key)

    messages = Storage.list_dm_tail(dm.key, limit: @tail_limit)
    events = Enum.map(messages, &Event.DmMessage.from_message/1)

    state = %{
      dm: dm,
      tail: events,
      idle_ref: schedule_idle(),
      stopped_reason: nil
    }

    active = RuntimeCounters.increment(:conversations_active, 1)
    emit_active(dm.key, active)
    :telemetry.execute([:fleetlm, :conversation, :started], %{count: 1}, %{dm_key: dm.key})

    {:ok, state}
  end

  @impl true
  def handle_call({:ensure_open, initiator_id, other_participant_id, initial_text}, _from, state) do
    state = reschedule_idle(state)

    with true <- DmKey.includes?(state.dm, initiator_id),
         true <- DmKey.includes?(state.dm, other_participant_id),
         trimmed <- normalize_text(initial_text) do
      if trimmed do
        case do_send_message(trimmed, initiator_id, other_participant_id, %{}, state) do
          {:ok, event, new_state} ->
            {:reply, {:ok, %{dm_key: state.dm.key, initial_message: event}}, new_state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
      else
        # Ensure inbox entries are warmed even without initial message
        notify_inbox(state, nil)
        {:reply, {:ok, %{dm_key: state.dm.key, initial_message: nil}}, state}
      end
    else
      _ -> {:reply, {:error, :unauthorised}, state}
    end
  end

  @impl true
  def handle_call({:send_message, sender_id, recipient_id, text, metadata}, _from, state) do
    state = reschedule_idle(state)
    metadata = metadata || %{}

    with true <- DmKey.includes?(state.dm, sender_id),
         expected_recipient <- DmKey.other_participant(state.dm, sender_id),
         true <- recipient_id == expected_recipient,
         trimmed <- normalize_text(text),
         true <- trimmed not in [nil, ""] do
      case do_send_message(trimmed, sender_id, recipient_id, metadata, state) do
        {:ok, event, new_state} -> {:reply, {:ok, event}, new_state}
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    else
      _ ->
        {:reply, {:error, :invalid_participant}, state}
    end
  rescue
    e in ArgumentError -> {:reply, {:error, e}, state}
  end

  @impl true
  def handle_call({:history, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 40)

    events =
      state.tail
      |> Enum.reverse()
      |> Enum.take(limit)

    {:reply, events, reschedule_idle(state)}
  end

  @impl true
  def handle_call(:ping, _from, state) do
    {:reply, :pong, state}
  end

  @impl true
  def handle_cast(:heartbeat, state) do
    {:noreply, reschedule_idle(state)}
  end

  @impl true
  def handle_info(:idle_timeout, state) do
    {:stop, :normal, %{state | stopped_reason: :idle}}
  end

  @impl true
  def terminate(reason, state) do
    if state[:idle_ref], do: Process.cancel_timer(state.idle_ref)
    emit_stopped(state, state[:stopped_reason] || normalize_reason(reason))
    :ok
  end

  ## Helpers

  defp do_send_message(text, sender_id, recipient_id, metadata, state) do
    case Storage.persist_dm_message(state.dm.key, sender_id, recipient_id, text, metadata) do
      {:ok, message} ->
        event = Event.DmMessage.from_message(message)
        new_state = put_in(state.tail, update_tail(state.tail, event))

        Events.publish_dm_message(event)
        notify_inbox(state, event)

        {:ok, event, reschedule_idle(new_state)}

      {:error, error} ->
        {:error, error}
    end
  end

  defp update_tail(tail, event) do
    [event | tail]
    |> Enum.take(@tail_limit)
  end

  defp notify_inbox(state, nil) do
    InboxServer.touch_conversation(state.dm.first, state.dm.key, state.dm.second)
    InboxServer.touch_conversation(state.dm.second, state.dm.key, state.dm.first)
  end

  defp notify_inbox(state, %Event.DmMessage{} = event) do
    InboxServer.record_message(state.dm.first, state.dm.key, event)
    InboxServer.record_message(state.dm.second, state.dm.key, event)
  end

  defp emit_stopped(state, reason) do
    active = RuntimeCounters.increment(:conversations_active, -1)
    emit_active(state.dm.key, active)

    :telemetry.execute([:fleetlm, :conversation, :stopped], %{count: 1}, %{
      dm_key: state.dm.key,
      reason: reason
    })
  end

  defp emit_active(dm_key, count) do
    :telemetry.execute([:fleetlm, :conversation, :active], %{count: count}, %{dm_key: dm_key})
  end

  defp normalize_reason({:shutdown, inner}), do: normalize_reason(inner)
  defp normalize_reason(:normal), do: :normal
  defp normalize_reason(reason), do: reason

  defp normalize_text(text) when is_binary(text) do
    trimmed = String.trim(text)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_text(_), do: nil

  defp schedule_idle do
    Process.send_after(self(), :idle_timeout, @idle_timeout)
  end

  defp reschedule_idle(%{idle_ref: ref} = state) do
    if ref, do: Process.cancel_timer(ref)
    %{state | idle_ref: schedule_idle()}
  end
end
