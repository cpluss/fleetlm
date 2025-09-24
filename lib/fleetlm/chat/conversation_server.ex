defmodule Fleetlm.Chat.ConversationServer do
  @moduledoc """
  We maintain a per-conversation server that is responsible for serialising direct messages and emitting
  domain events. This allows us to scale the number of conversations we can support by having a single
  process per conversation. The servers are aggressively recycled after a period of inactivity.
  """

  use GenServer, restart: :transient

  alias Fleetlm.Chat.{Cache, DmKey, Events, Storage}
  alias Fleetlm.Observability

  @tail_limit 100
  @registry Fleetlm.Chat.ConversationRegistry
  @idle_timeout Application.compile_env(:fleetlm, :conversation_idle_ms, 180_000)

  ## Public API

  @spec via(DmKey.t()) :: {:via, Registry, {module(), String.t()}}
  def via(%DmKey{key: key}), do: {:via, Registry, {@registry, key}}

  @spec start_link(DmKey.t()) :: GenServer.on_start()
  def start_link(%DmKey{} = dm_key) do
    GenServer.start_link(__MODULE__, dm_key, name: via(dm_key))
  end

  @spec send_message(DmKey.t(), String.t(), String.t(), String.t() | nil, map()) ::
          {:ok, Events.DmMessage.t()} | {:error, term()}
  def send_message(%DmKey{} = dm_key, sender_id, recipient_id, text, metadata) do
    GenServer.call(via(dm_key), {:send_message, sender_id, recipient_id, text, metadata})
  end

  @spec heartbeat(DmKey.t()) :: :ok
  def heartbeat(%DmKey{} = dm_key) do
    GenServer.cast(via(dm_key), :heartbeat)
  end

  @spec ensure_open(DmKey.t(), String.t(), String.t(), String.t() | nil) ::
          {:ok, %{dm_key: String.t(), initial_message: Events.DmMessage.t() | nil}}
          | {:error, term()}
  def ensure_open(%DmKey{} = dm_key, initiator_id, other_participant_id, initial_text) do
    GenServer.call(via(dm_key), {:ensure_open, initiator_id, other_participant_id, initial_text})
  end

  ## GenServer callbacks

  @impl true
  def init(%DmKey{} = dm) do
    seed_tail(dm.key)

    state = %{
      dm: dm,
      idle_ref: schedule_idle(),
      stopped_reason: nil
    }

    Observability.conversation_started(dm.key)

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
          {:ok, event} ->
            {:reply, {:ok, %{dm_key: state.dm.key, initial_message: event}},
             reschedule_idle(state)}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
      else
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
        {:ok, event} -> {:reply, {:ok, event}, reschedule_idle(state)}
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

    Observability.conversation_stopped(
      state.dm.key,
      state[:stopped_reason] || normalize_reason(reason)
    )

    :ok
  end

  ## Helpers

  defp do_send_message(text, sender_id, recipient_id, metadata, state) do
    case Storage.persist_dm_message(state.dm.key, sender_id, recipient_id, text, metadata) do
      {:ok, message} ->
        event = Events.DmMessage.from_message(message)

        _ = ensure_tail_appended(state.dm.key, event)

        # Actual message push
        Events.publish_dm_message(event)
        # Notifications
        Events.publish_dm_activity(event)
        # Telemetry - so we can count this stuff
        Observability.message_sent(state.dm.key, sender_id, recipient_id, metadata)

        {:ok, event}

      {:error, error} ->
        {:error, error}
    end
  end

  defp normalize_reason({:shutdown, inner}), do: normalize_reason(inner)
  defp normalize_reason(:normal), do: :normal
  defp normalize_reason(reason), do: reason

  defp normalize_text(text) when is_binary(text) do
    trimmed = String.trim(text)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_text(_), do: nil

  defp seed_tail(dm_key) do
    case Cache.fetch_tail(dm_key, limit: @tail_limit) do
      {:ok, _events} ->
        :ok

      :miss ->
        dm_key
        |> Storage.list_dm_tail(limit: @tail_limit)
        |> Enum.map(&Events.DmMessage.from_message/1)
        |> then(&Cache.put_tail(dm_key, &1))
        |> case do
          :ok -> :ok
          {:error, _reason} -> :ok
        end

      {:error, _reason} ->
        :ok
    end
  end

  defp ensure_tail_appended(dm_key, event) do
    case Cache.append_to_tail(dm_key, event, limit: @tail_limit) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp schedule_idle do
    Process.send_after(self(), :idle_timeout, @idle_timeout)
  end

  defp reschedule_idle(%{idle_ref: ref} = state) do
    if ref, do: Process.cancel_timer(ref)
    %{state | idle_ref: schedule_idle()}
  end
end
