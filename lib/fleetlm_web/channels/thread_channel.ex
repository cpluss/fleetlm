defmodule FleetlmWeb.ThreadChannel do
  use FleetlmWeb, :channel

  alias Fleetlm.Chat
  alias Phoenix.PubSub

  @pubsub Fleetlm.PubSub
  @history_limit 40

  @impl true
  def join("dm:" <> dm_participants, _params, socket) do
    participant_id = socket.assigns.participant_id

    case parse_dm_participants(dm_participants) do
      {:ok, user_a, user_b} when participant_id in [user_a, user_b] ->
        :ok = PubSub.subscribe(@pubsub, "dm:" <> dm_participants)

        # Get conversation history
        history =
          user_a
          |> Chat.get_dm_conversation(user_b, limit: @history_limit)
          |> Enum.reverse()
          |> Enum.map(&serialize_dm_message/1)

        other_participant_id = if participant_id == user_a, do: user_b, else: user_a

        {:ok, %{"messages" => history, "other_participant_id" => other_participant_id},
         assign(socket, :dm_participants, {user_a, user_b})}

      {:ok, _user_a, _user_b} ->
        {:error, %{reason: "unauthorized"}}

      {:error, reason} ->
        {:error, %{reason: reason}}
    end
  end

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
      socket.assigns[:dm_participants] ->
        {user_a, user_b} = socket.assigns.dm_participants
        recipient_id = if sender_id == user_a, do: user_b, else: user_a

        attrs = %{
          sender_id: sender_id,
          recipient_id: recipient_id,
          text: payload["text"],
          metadata: payload["metadata"] || %{}
        }

        case Chat.dispatch_message(attrs) do
          {:ok, message} ->
            # Broadcast to DM channel
            PubSub.broadcast(@pubsub, "dm:#{user_a}|#{user_b}", {:dm_message, message})
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
            # Broadcast to all listeners
            PubSub.broadcast(@pubsub, "broadcast", {:broadcast_message, message})
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

  defp parse_dm_participants(participants_string) do
    case String.split(participants_string, "|", parts: 2) do
      [user_a, user_b] when user_a != user_b ->
        {:ok, user_a, user_b}

      _ ->
        {:error, "invalid DM participants format, expected 'user_a|user_b'"}
    end
  end

  defp serialize_dm_message(message) do
    %{
      "id" => message.id,
      "sender_id" => message.sender_id,
      "recipient_id" => message.recipient_id,
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