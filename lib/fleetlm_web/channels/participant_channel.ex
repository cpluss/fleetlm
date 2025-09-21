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

      threads =
        participant_id
        |> Chat.list_threads_for_participant()
        |> Enum.map(&serialize_participant_thread/1)

      {:ok, %{"threads" => threads},
       socket
       |> assign(:pending_updates, %{})
       |> assign(:tick_timer, schedule_tick())}
    else
      {:error, %{reason: "unauthorized"}}
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

  defp serialize_participant_thread(participant) do
    %{
      "thread_id" => participant.thread_id,
      "role" => participant.role,
      "joined_at" => encode_datetime(participant.joined_at),
      "last_message_at" => encode_datetime(participant.last_message_at),
      "last_message_preview" => participant.last_message_preview,
      "read_cursor_at" => encode_datetime(participant.read_cursor_at),
      "thread" => serialize_thread(participant.thread)
    }
  end

  defp serialize_thread(%Fleetlm.Chat.Threads.Thread{} = thread) do
    %{
      "id" => thread.id,
      "kind" => thread.kind,
      "dm_key" => thread.dm_key,
      "created_at" => encode_datetime(thread.created_at)
    }
  end

  defp serialize_thread(nil), do: nil

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
