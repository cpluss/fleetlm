defmodule Fleetlm.Chat.InboxServer do
  @moduledoc """
  We maintain an inbox per connected participant. This is responsible for tracking the inbox metadata
  such as unread counts and last message previews.
  """

  use GenServer

  alias Fleetlm.Chat.{DmKey, Event, Events, Storage}
  alias Fleetlm.Telemetry.RuntimeCounters

  @registry Fleetlm.Chat.InboxRegistry
  @flush_interval 200
  @idle_timeout Application.compile_env(:fleetlm, :inbox_idle_ms, 30_000)

  ## Public API

  @spec via(String.t()) :: {:via, Registry, {module(), String.t()}}
  def via(participant_id), do: {:via, Registry, {@registry, participant_id}}

  @spec start_link(String.t()) :: GenServer.on_start()
  def start_link(participant_id) when is_binary(participant_id) do
    GenServer.start_link(__MODULE__, participant_id, name: via(participant_id))
  end

  @spec snapshot(String.t()) :: [Event.DmActivity.t()]
  def snapshot(participant_id) do
    GenServer.call(via(participant_id), :snapshot)
  end

  @spec touch_conversation(String.t(), String.t(), String.t()) :: :ok
  def touch_conversation(participant_id, dm_key, other_participant_id) do
    GenServer.cast(via(participant_id), {:touch, dm_key, other_participant_id})
  end

  @spec record_message(String.t(), String.t(), Event.DmMessage.t()) :: :ok
  def record_message(participant_id, dm_key, %Event.DmMessage{} = event) do
    GenServer.cast(via(participant_id), {:message, dm_key, event})
  end

  @spec heartbeat(String.t()) :: :ok
  def heartbeat(participant_id) do
    GenServer.cast(via(participant_id), :heartbeat)
  end

  ## GenServer callbacks

  @impl true
  def init(participant_id) do
    threads = Storage.list_dm_threads(participant_id)

    conversations =
      threads
      |> Enum.reduce(%{}, fn thread, acc ->
        Map.put(acc, thread.dm_key, %{
          dm_key: thread.dm_key,
          other_participant_id: thread.other_participant_id,
          last_sender_id: nil,
          last_message_text: thread.last_message_text,
          last_message_at: thread.last_message_at,
          unread_count: 0
        })
      end)

    state = %{
      participant_id: participant_id,
      conversations: conversations,
      pending: %{},
      flush_ref: nil,
      idle_ref: schedule_idle(),
      stopped_reason: nil
    }

    active = RuntimeCounters.increment(:inboxes_active, 1)
    emit_active(participant_id, active)

    :telemetry.execute([:fleetlm, :inbox, :started], %{count: 1}, %{
      participant_id: participant_id
    })

    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    activities =
      state.conversations
      |> Enum.map(fn {dm_key, convo} -> to_activity(dm_key, state.participant_id, convo) end)
      |> Enum.sort_by(&{&1.last_message_at || ~N[0000-01-01 00:00:00], &1.dm_key}, :desc)

    {:reply, activities, reschedule_idle(state)}
  end

  @impl true
  def handle_call(:ping, _from, state) do
    {:reply, :pong, state}
  end

  @impl true
  def handle_cast({:touch, dm_key, other_participant_id}, state) do
    conversations =
      Map.update(
        state.conversations,
        dm_key,
        %{
          dm_key: dm_key,
          other_participant_id: other_participant_id,
          last_sender_id: nil,
          last_message_text: nil,
          last_message_at: nil,
          unread_count: 0
        },
        & &1
      )

    state = %{state | conversations: conversations}
    state = reschedule_idle(state)
    {:noreply, schedule_flush_if_needed(state, dm_key)}
  end

  @impl true
  def handle_cast({:message, dm_key, %Event.DmMessage{} = message}, state) do
    dm = DmKey.parse!(dm_key)
    other = DmKey.other_participant(dm, state.participant_id)

    conversations =
      Map.update(
        state.conversations,
        dm_key,
        %{
          dm_key: dm_key,
          other_participant_id: other,
          last_sender_id: message.sender_id,
          last_message_text: message.text,
          last_message_at: message.created_at,
          unread_count: unread_for(message, state.participant_id)
        },
        fn convo ->
          unread =
            if message.sender_id == state.participant_id do
              0
            else
              convo.unread_count + 1
            end

          %{
            convo
            | other_participant_id: other,
              last_sender_id: message.sender_id,
              last_message_text: message.text,
              last_message_at: message.created_at,
              unread_count: unread
          }
        end
      )

    state = %{state | conversations: conversations}
    state = reschedule_idle(state)
    {:noreply, schedule_flush_if_needed(state, dm_key)}
  end

  @impl true
  def handle_cast(:heartbeat, state) do
    {:noreply, reschedule_idle(state)}
  end

  @impl true
  def handle_info(:flush, state) do
    Enum.each(state.pending, fn {_dm_key, activity} ->
      Events.publish_dm_activity(activity)
    end)

    {:noreply, %{state | pending: %{}, flush_ref: nil} |> reschedule_idle()}
  end

  @impl true
  def handle_info(:idle_timeout, state) do
    {:stop, :normal, %{state | stopped_reason: :idle}}
  end

  @impl true
  def terminate(reason, state) do
    if state.flush_ref, do: Process.cancel_timer(state.flush_ref)
    if state[:idle_ref], do: Process.cancel_timer(state.idle_ref)
    emit_stopped(state, state[:stopped_reason] || normalize_reason(reason))
    :ok
  end

  ## Helpers

  defp schedule_flush_if_needed(state, dm_key) do
    convo_entry =
      case Map.get(state.conversations, dm_key) do
        %{} = convo ->
          convo

        _ ->
          dm = DmKey.parse!(dm_key)

          default = %{
            dm_key: dm_key,
            other_participant_id: DmKey.other_participant(dm, state.participant_id),
            last_sender_id: nil,
            last_message_text: nil,
            last_message_at: nil,
            unread_count: 0
          }

          default
      end

    conversations = Map.put(state.conversations, dm_key, convo_entry)
    activity = to_activity(dm_key, state.participant_id, convo_entry)

    state =
      state
      |> Map.put(:conversations, conversations)
      |> put_in([:pending, dm_key], activity)

    if state.flush_ref do
      state
    else
      ref = Process.send_after(self(), :flush, @flush_interval)
      %{state | flush_ref: ref}
    end
  end

  defp to_activity(dm_key, participant_id, convo) do
    dm = DmKey.parse!(dm_key)

    other =
      Map.get(convo, :other_participant_id) ||
        Map.get(convo, "other_participant_id") ||
        DmKey.other_participant(dm, participant_id)

    last_sender = Map.get(convo, :last_sender_id) || Map.get(convo, "last_sender_id")
    last_text = Map.get(convo, :last_message_text) || Map.get(convo, "last_message_text")
    last_at = Map.get(convo, :last_message_at) || Map.get(convo, "last_message_at")
    unread = Map.get(convo, :unread_count) || Map.get(convo, "unread_count") || 0

    %Event.DmActivity{
      participant_id: participant_id,
      dm_key: dm.key,
      other_participant_id: other,
      last_sender_id: last_sender,
      last_message_text: last_text,
      last_message_at: last_at,
      unread_count: unread
    }
  end

  defp unread_for(message, participant_id) do
    if message.sender_id == participant_id, do: 0, else: 1
  end

  defp schedule_idle do
    Process.send_after(self(), :idle_timeout, @idle_timeout)
  end

  defp reschedule_idle(state) do
    state
    |> cancel_idle()
    |> Map.put(:idle_ref, schedule_idle())
  end

  defp cancel_idle(%{idle_ref: ref} = state) when is_reference(ref) do
    Process.cancel_timer(ref)
    %{state | idle_ref: nil}
  end

  defp cancel_idle(state), do: %{state | idle_ref: nil}

  defp emit_stopped(state, reason) do
    active = RuntimeCounters.increment(:inboxes_active, -1)
    emit_active(state.participant_id, active)

    :telemetry.execute([:fleetlm, :inbox, :stopped], %{count: 1}, %{
      participant_id: state.participant_id,
      reason: reason
    })
  end

  defp emit_active(participant_id, count) do
    :telemetry.execute([:fleetlm, :inbox, :active], %{count: count}, %{
      participant_id: participant_id
    })
  end

  defp normalize_reason({:shutdown, inner}), do: normalize_reason(inner)
  defp normalize_reason(:normal), do: :normal
  defp normalize_reason(reason), do: reason
end
