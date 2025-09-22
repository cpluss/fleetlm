defmodule FleetlmWeb.ThreadChannel do
  use FleetlmWeb, :channel

  alias Fleetlm.Chat
  alias Phoenix.PubSub

  @pubsub Fleetlm.PubSub
  @history_limit 40

  # DM Channel: dm:user:alice:user:bob
  @impl true
  def join("dm:" <> dm_key, _params, socket) do
    participant_id = socket.assigns.participant_id

    # Verify participant is part of this DM by checking if they appear in the dm_key
    if participant_in_dm?(participant_id, dm_key) do
      :ok = PubSub.subscribe(@pubsub, "dm:" <> dm_key)

      # Get conversation history using dm_key
      history =
        dm_key
        |> Chat.get_dm_conversation_by_key(limit: @history_limit)
        |> Enum.reverse()
        |> Enum.map(&serialize_dm_message/1)

      {:ok, %{"messages" => history, "dm_key" => dm_key},
       assign(socket, :dm_key, dm_key)}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  # Broadcast Channel: broadcast
  @impl true
  def join("broadcast", _params, socket) do
    :ok = PubSub.subscribe(@pubsub, "broadcast")

    # Get recent broadcast messages
    history =
      Chat.list_broadcast_messages(limit: @history_limit)
      |> Enum.reverse()
      |> Enum.map(&serialize_broadcast_message/1)

    {:ok, %{"messages" => history}, assign(socket, :broadcast, true)}
  end

  @impl true
  def handle_in("message:new", payload, socket) do
    sender_id = socket.assigns.participant_id

    cond do
      socket.assigns[:dm_key] ->
        dm_key = socket.assigns.dm_key
        recipient_id = get_other_participant(dm_key, sender_id)

        attrs = %{
          sender_id: sender_id,
          recipient_id: recipient_id,
          text: payload["text"],
          metadata: payload["metadata"] || %{}
        }

        case Chat.dispatch_message(attrs) do
          {:ok, message} ->
            # PubSub broadcasting is now handled by Chat.Events automatically
            {:reply, {:ok, serialize_dm_message(message)}, socket}

          {:error, reason} ->
            {:reply, {:error, %{reason: inspect(reason)}}, socket}
        end

      socket.assigns[:broadcast] ->
        attrs = %{
          sender_id: sender_id,
          text: payload["text"],
          metadata: payload["metadata"] || %{}
        }

        case Chat.dispatch_message(attrs) do
          {:ok, message} ->
            # PubSub broadcasting is now handled by Chat.Events automatically
            {:reply, {:ok, serialize_broadcast_message(message)}, socket}

          {:error, reason} ->
            {:reply, {:error, %{reason: inspect(reason)}}, socket}
        end

      true ->
        {:reply, {:error, %{reason: "invalid channel type"}}, socket}
    end
  end

  @impl true
  def handle_info({:dm_message, message}, socket) do
    push(socket, "message", serialize_dm_message(message))
    {:noreply, socket}
  end

  @impl true
  def handle_info({:broadcast_message, message}, socket) do
    push(socket, "message", serialize_broadcast_message(message))
    {:noreply, socket}
  end

  defp participant_in_dm?(participant_id, dm_key) do
    # dm_key format: "participant_a:participant_b" (sorted)
    String.contains?(dm_key, participant_id)
  end

  defp get_other_participant(dm_key, participant_id) do
    # dm_key format: "user:alice:user:bob" (sorted participant IDs)
    # Split on ":" and rejoin to get the two participant IDs
    parts = String.split(dm_key, ":")

    case parts do
      [type_a, id_a, type_b, id_b] when length(parts) == 4 ->
        participant_a = "#{type_a}:#{id_a}"
        participant_b = "#{type_b}:#{id_b}"
        if participant_a == participant_id, do: participant_b, else: participant_a

      _ ->
        raise "Invalid dm_key format: #{dm_key}"
    end
  end

  defp serialize_dm_message(message) do
    %{
      "id" => message.id,
      "sender_id" => message.sender_id,
      "recipient_id" => message.recipient_id,
      "dm_key" => message.dm_key,
      "text" => message.text,
      "metadata" => message.metadata,
      "created_at" => encode_datetime(message.created_at)
    }
  end

  defp serialize_broadcast_message(message) do
    %{
      "id" => message.id,
      "sender_id" => message.sender_id,
      "text" => message.text,
      "metadata" => message.metadata,
      "created_at" => encode_datetime(message.created_at)
    }
  end

  defp encode_datetime(nil), do: nil
  defp encode_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp encode_datetime(%NaiveDateTime{} = naive), do: NaiveDateTime.to_iso8601(naive)
end