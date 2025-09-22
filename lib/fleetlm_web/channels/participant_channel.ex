defmodule FleetlmWeb.ParticipantChannel do
  use FleetlmWeb, :channel

  alias Fleetlm.Chat
  alias Phoenix.PubSub

  @pubsub Fleetlm.PubSub
  @tick_interval Application.compile_env(:fleetlm, :participant_tick_interval_ms, 1_000)

  @impl true
  def join("participant:" <> participant_id, _params, socket) do
    if participant_id == socket.assigns.participant_id do
      :ok = PubSub.subscribe(@pubsub, "participant:" <> participant_id)

      dm_threads =
        participant_id
        |> Chat.get_dm_threads_for_user()
        |> Enum.map(&serialize_dm_thread/1)

      {:ok, %{"dm_threads" => dm_threads},
       socket
       |> assign(:pending_updates, %{})
       |> assign(:tick_timer, schedule_tick())}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_in("dm:create", %{"participant_id" => other_participant_id, "message" => message}, socket) do
    current_participant_id = socket.assigns.participant_id

    try do
      dm_key = Chat.generate_dm_key(current_participant_id, other_participant_id)

      # Send the initial message if provided
      if message && String.trim(message) != "" do
        case Chat.dispatch_message(%{
               sender_id: current_participant_id,
               recipient_id: other_participant_id,
               text: message
             }) do
          {:ok, _message} -> :ok
          {:error, _} -> :ok  # Continue even if message sending fails
        end
      end

      # Return dm_key for the new architecture
      {:reply, {:ok, %{"dm_key" => dm_key, "thread_id" => dm_key}}, socket}
    rescue
      error ->
        {:reply, {:error, %{"reason" => "failed to create DM: #{inspect(error)}"}}, socket}
    end
  end

  @impl true
  def handle_info({:thread_updated, summary}, socket) do
    updates = socket.assigns.pending_updates
    serialized = serialize_summary(summary)
    updates = Map.put(updates, serialized["thread_id"], serialized)

    {:noreply, assign(socket, :pending_updates, updates)}
  end

  @impl true
  def handle_info({:dm_activity, metadata}, socket) do
    updates = socket.assigns.pending_updates
    dm_key = metadata[:dm_key] || metadata["dm_key"]
    updates = Map.put(updates, dm_key, metadata)

    {:noreply, assign(socket, :pending_updates, updates)}
  end

  @impl true
  def handle_info(:deliver_tick, socket) do
    updates = socket.assigns.pending_updates

    socket = assign(socket, :tick_timer, schedule_tick())

    if map_size(updates) > 0 do
      push(socket, "tick", %{"updates" => Map.values(updates)})
      {:noreply, assign(socket, :pending_updates, %{})}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def terminate(_reason, socket) do
    if timer = socket.assigns[:tick_timer], do: Process.cancel_timer(timer)
    :ok
  end

  defp serialize_dm_thread(dm_thread) do
    %{
      "dm_key" => dm_thread.dm_key,
      "other_participant_id" => dm_thread.other_participant_id,
      "last_message_at" => encode_datetime(dm_thread.last_message_at),
      "last_message_text" => dm_thread.last_message_text
    }
  end

  defp serialize_summary(summary) do
    summary
    |> Map.take([
      :thread_id,
      :participant_id,
      :last_message_at,
      :last_message_preview,
      :sender_id
    ])
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      encoded = if key == :last_message_at, do: encode_datetime(value), else: value
      Map.put(acc, to_string(key), encoded)
    end)
  end

  defp encode_datetime(nil), do: nil
  defp encode_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp encode_datetime(%NaiveDateTime{} = naive), do: NaiveDateTime.to_iso8601(naive)
  defp encode_datetime(value) when is_binary(value), do: value

  defp schedule_tick do
    Process.send_after(self(), :deliver_tick, @tick_interval)
  end
end
