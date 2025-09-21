defmodule FleetlmWeb.ParticipantChannel do
  use FleetlmWeb, :channel

  alias Fleetlm.Chat
  alias Phoenix.PubSub

  @pubsub Fleetlm.PubSub

  @impl true
  def join("participant:" <> participant_id, _params, socket) do
    if participant_id == socket.assigns.participant_id do
      :ok = PubSub.subscribe(@pubsub, "participant:" <> participant_id)

      threads =
        participant_id
        |> Chat.list_threads_for_participant()
        |> Enum.map(&serialize_participant_thread/1)

      {:ok, %{"threads" => threads}, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_in("tick", payload, socket) do
    participant_id = socket.assigns.participant_id

    entries = Map.get(payload, "threads", [])

    updates =
      entries
      |> Enum.reduce([], fn entry, acc ->
        case Map.fetch(entry, "thread_id") do
          :error ->
            acc

          {:ok, thread_id} ->
            cursor = Map.get(entry, "cursor")

            case Chat.tick_thread(thread_id, participant_id, cursor) do
              {:updated, payload} -> [serialize_tick(payload) | acc]
              :idle -> acc
              {:error, :not_participant} -> acc
              {:error, _} -> acc
            end
        end
      end)
      |> Enum.reverse()

    {:reply, {:ok, %{"updates" => updates}}, socket}
  end

  @impl true
  def handle_info({:thread_updated, summary}, socket) do
    push(socket, "thread_updated", serialize_summary(summary))
    {:noreply, socket}
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

  defp serialize_tick(%{recent_messages: messages} = payload) do
    %{
      "thread_id" => payload.thread_id,
      "participant_id" => payload.participant_id,
      "last_message_at" => encode_datetime(payload.last_message_at),
      "recent_messages" => Enum.map(messages, &serialize_message/1)
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

  defp serialize_message(message) do
    %{
      "id" => message.id,
      "thread_id" => message.thread_id,
      "sender_id" => message.sender_id,
      "role" => message.role,
      "kind" => message.kind,
      "text" => message.text,
      "metadata" => message.metadata,
      "created_at" => encode_datetime(message.created_at)
    }
  end

  defp encode_datetime(nil), do: nil
  defp encode_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp encode_datetime(%NaiveDateTime{} = naive), do: NaiveDateTime.to_iso8601(naive)
  defp encode_datetime(value) when is_binary(value), do: value
end
