defmodule FleetlmWeb.ThreadChannel do
  use FleetlmWeb, :channel

  alias Fleetlm.Chat
  alias Fleetlm.Chat.{Dispatcher, DmKey, Event}
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

      # Ensure runtime server is hot and fetch history
      history =
        dm_key
        |> Dispatcher.convo_history(limit: @history_limit)
        |> Enum.reverse()
        |> Enum.map(&Event.DmMessage.to_payload/1)

      {:ok, %{"messages" => history, "dm_key" => dm_key}, assign(socket, :dm_key, dm_key)}
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
      |> Enum.map(&Event.BroadcastMessage.to_payload/1)

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
          dm_key: dm_key,
          sender_id: sender_id,
          recipient_id: recipient_id,
          text: payload["text"],
          metadata: payload["metadata"] || %{}
        }

        case Dispatcher.send_message(attrs) do
          {:ok, event} ->
            {:reply, {:ok, Event.DmMessage.to_payload(event)}, socket}

          {:error, reason} ->
            {:reply, {:error, %{reason: inspect(reason)}}, socket}
        end

      socket.assigns[:broadcast] ->
        case Dispatcher.send_broadcast(sender_id, payload["text"], payload["metadata"] || %{}) do
          {:ok, event} ->
            {:reply, {:ok, Event.BroadcastMessage.to_payload(event)}, socket}

          {:error, reason} ->
            {:reply, {:error, %{reason: inspect(reason)}}, socket}
        end

      true ->
        {:reply, {:error, %{reason: "invalid channel type"}}, socket}
    end
  end

  @impl true
  def handle_info({:dm_message, payload}, socket) do
    push(socket, "message", payload)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:broadcast_message, payload}, socket) do
    push(socket, "message", payload)
    {:noreply, socket}
  end

  defp participant_in_dm?(participant_id, dm_key) do
    dm = DmKey.parse!(dm_key)
    DmKey.includes?(dm, participant_id)
  end

  defp get_other_participant(dm_key, participant_id) do
    dm = DmKey.parse!(dm_key)
    DmKey.other_participant(dm, participant_id)
  end
end
