defmodule Fleetlm.Chat.InboxServer do
  @moduledoc false

  use GenServer, restart: :transient

  alias Fleetlm.Chat.{Cache, Events, InboxSupervisor}
  alias Fleetlm.Telemetry.RuntimeCounters
  alias Phoenix.PubSub

  @pubsub Fleetlm.PubSub
  @debounce Application.compile_env(:fleetlm, :inbox_debounce_ms, 150)
  @max_interval Application.compile_env(:fleetlm, :inbox_max_interval_ms, 2_000)

  @type state :: %{
          participant_id: String.t(),
          entries: %{optional(String.t()) => Events.DmActivity.t()},
          pending: %{optional(String.t()) => Events.DmActivity.t()},
          timer_ref: reference | nil,
          last_flush: integer
        }

  ## Public API

  @spec start_link(String.t()) :: GenServer.on_start()
  def start_link(participant_id) when is_binary(participant_id) do
    GenServer.start_link(__MODULE__, participant_id, name: via(participant_id))
  end

  @spec via(String.t()) :: {:via, Registry, {module(), String.t()}}
  def via(participant_id), do: {:via, Registry, {Fleetlm.Chat.InboxRegistry, participant_id}}

  @spec ensure_started(String.t()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(participant_id), do: InboxSupervisor.ensure_started(participant_id)

  @spec snapshot(String.t()) :: {:ok, [map()]} | {:error, term()}
  def snapshot(participant_id) do
    GenServer.call(via(participant_id), :snapshot)
  end

  @spec mark_read(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def mark_read(participant_id, dm_key, opts \\ []) do
    up_to_ts = Keyword.get(opts, :up_to_ts)
    GenServer.call(via(participant_id), {:mark_read, dm_key, up_to_ts})
  end

  @spec enqueue_activity(String.t(), Events.DmActivity.t()) :: :ok | {:error, term()}
  def enqueue_activity(participant_id, %Events.DmActivity{} = activity) do
    GenServer.cast(via(participant_id), {:activity, activity})
  end

  @spec flush(String.t()) :: :ok
  def flush(participant_id) do
    GenServer.call(via(participant_id), :flush)
  end

  ## GenServer callbacks

  @impl true
  def init(participant_id) do
    RuntimeCounters.increment(:inboxes_active, 1)

    entries = load_entries(participant_id)

    state = %{
      participant_id: participant_id,
      entries: entries,
      pending: %{},
      timer_ref: nil,
      last_flush: monotonic_millis()
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, {:ok, entries_to_payloads(state.entries)}, state}
  end

  def handle_call({:mark_read, dm_key, _up_to_ts}, _from, state) do
    case Map.fetch(state.entries, dm_key) do
      :error ->
        {:reply, :ok, state}

      {:ok, entry} ->
        updated = %Events.DmActivity{entry | unread_count: 0}

        state =
          state
          |> put_entry(updated)
          |> maybe_schedule_flush()

        {:reply, :ok, state}
    end
  end

  def handle_call(:flush, _from, state) do
    {:reply, :ok, do_flush(state)}
  end

  @impl true
  def handle_cast({:activity, %Events.DmActivity{} = activity}, state) do
    state =
      state
      |> apply_activity(activity)
      |> maybe_schedule_flush()

    {:noreply, state}
  end

  @impl true
  def handle_info(:flush, state) do
    {:noreply, do_flush(state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, _state) do
    RuntimeCounters.increment(:inboxes_active, -1)
    :ok
  end

  ## Helpers

  defp load_entries(participant_id) do
    case Cache.fetch_inbox_snapshot(participant_id) do
      {:ok, entries} ->
        entries_list_to_map(entries)

      :miss ->
        entries = Fleetlm.Chat.inbox_snapshot(participant_id)
        Cache.put_inbox_snapshot(participant_id, entries)
        entries_list_to_map(entries)

      {:error, _reason} ->
        entries = Fleetlm.Chat.inbox_snapshot(participant_id)
        Cache.put_inbox_snapshot(participant_id, entries)
        entries_list_to_map(entries)
    end
  end

  defp apply_activity(state, activity) do
    dm_key = activity.dm_key
    existing = Map.get(state.entries, dm_key)

    unread_count =
      case activity.last_sender_id do
        sender when sender == state.participant_id -> 0
        _ -> ((existing && existing.unread_count) || 0) + 1
      end

    updated = %Events.DmActivity{
      activity
      | unread_count: unread_count
    }

    state
    |> put_entry(updated)
  end

  defp put_entry(state, %Events.DmActivity{} = entry) do
    %{
      state
      | entries: Map.put(state.entries, entry.dm_key, entry),
        pending: Map.put(state.pending, entry.dm_key, entry)
    }
  end

  defp maybe_schedule_flush(%{timer_ref: nil} = state) do
    ref = Process.send_after(self(), :flush, @debounce)
    %{state | timer_ref: ref}
  end

  defp maybe_schedule_flush(%{timer_ref: _ref, last_flush: last_flush} = state) do
    if monotonic_millis() - last_flush >= @max_interval do
      do_flush(state)
    else
      state
    end
  end

  defp do_flush(%{pending: pending} = state) when map_size(pending) == 0 do
    cancel_timer(state)
  end

  defp do_flush(state) do
    updates =
      state.pending
      |> Map.values()
      |> entries_to_payloads()

    Cache.put_inbox_snapshot(state.participant_id, Map.values(state.entries))

    PubSub.broadcast(
      @pubsub,
      inbox_topic(state.participant_id),
      {:inbox_delta, %{updates: updates}}
    )

    state
    |> cancel_timer()
    |> Map.put(:pending, %{})
    |> Map.put(:last_flush, monotonic_millis())
  end

  defp cancel_timer(%{timer_ref: nil} = state), do: state

  defp cancel_timer(%{timer_ref: ref} = state) do
    Process.cancel_timer(ref)
    %{state | timer_ref: nil}
  end

  defp entries_to_payloads(entries) when is_map(entries) do
    entries
    |> Map.values()
    |> entries_to_payloads()
  end

  defp entries_to_payloads(entries) when is_list(entries) do
    Enum.map(entries, &Events.DmActivity.to_payload/1)
  end

  defp entries_list_to_map(entries) when is_list(entries) do
    entries
    |> Enum.map(&ensure_activity_struct/1)
    |> Map.new(fn entry -> {entry.dm_key, entry} end)
  end

  defp entries_list_to_map(_), do: %{}

  defp ensure_activity_struct(%Events.DmActivity{} = entry), do: entry

  defp ensure_activity_struct(payload) when is_map(payload) do
    struct!(Events.DmActivity, %{
      participant_id: payload[:participant_id] || payload["participant_id"],
      dm_key: payload[:dm_key] || payload["dm_key"],
      other_participant_id: payload[:other_participant_id] || payload["other_participant_id"],
      last_sender_id: payload[:last_sender_id] || payload["last_sender_id"],
      last_message_text: payload[:last_message_text] || payload["last_message_text"],
      last_message_at: payload[:last_message_at] || payload["last_message_at"],
      unread_count: payload[:unread_count] || payload["unread_count"] || 0
    })
  end

  defp inbox_topic(participant_id), do: "inbox:" <> participant_id

  defp monotonic_millis do
    System.monotonic_time(:millisecond)
  end
end
