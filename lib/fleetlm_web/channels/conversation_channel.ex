defmodule FleetlmWeb.ConversationChannel do
  @moduledoc """
  The ConversationChannel is used to subscribe to a conversation, in order to receive messages
  as they are sent. This allows the client to only receive messages for conversations they care about
  (e.g. those displayed in the UI).
  """
  use FleetlmWeb, :channel

  alias Fleetlm.Chat
  alias Fleetlm.Chat.{DmKey, Event}
  alias Phoenix.PubSub

  @pubsub Fleetlm.PubSub
  @history_limit 40
  @broadcast_key "broadcast"

  @impl true
  def join("conversation", _params, socket) do
    {:ok, %{"subscriptions" => []}, assign(socket, :subscriptions, MapSet.new())}
  end

  @impl true
  def handle_in("conversation:subscribe", %{"dm_key" => dm_key}, socket) do
    participant_id = socket.assigns.participant_id

    cond do
      dm_key == @broadcast_key ->
        :ok = PubSub.subscribe(@pubsub, @broadcast_key)

        history =
          Chat.list_broadcast_messages(limit: @history_limit)
          |> Enum.reverse()
          |> Enum.map(&Event.BroadcastMessage.to_payload/1)

        subscriptions = MapSet.put(socket.assigns.subscriptions, @broadcast_key)

        {:reply, {:ok, %{"dm_key" => @broadcast_key, "messages" => history}},
         assign(socket, :subscriptions, subscriptions)}

      true ->
        with {:ok, dm} <- authorize_dm(dm_key, participant_id),
             {:ok, events} <- Chat.get_messages(dm.key, limit: @history_limit) do
          :ok = PubSub.subscribe(@pubsub, "dm:" <> dm.key)

          history = Enum.map(events, &Event.DmMessage.to_payload/1)

          subscriptions = MapSet.put(socket.assigns.subscriptions, dm.key)

          {:reply, {:ok, %{"dm_key" => dm.key, "messages" => history}},
           assign(socket, :subscriptions, subscriptions)}
        else
          {:error, reason} -> {:reply, {:error, %{reason: inspect(reason)}}, socket}
        end
    end
  end

  def handle_in("conversation:unsubscribe", %{"dm_key" => dm_key}, socket) do
    subscriptions = socket.assigns.subscriptions

    if MapSet.member?(subscriptions, dm_key) do
      if dm_key == @broadcast_key do
        PubSub.unsubscribe(@pubsub, @broadcast_key)
      else
        PubSub.unsubscribe(@pubsub, "dm:" <> dm_key)
      end

      {:reply, {:ok, %{"dm_key" => dm_key}},
       assign(socket, :subscriptions, MapSet.delete(subscriptions, dm_key))}
    else
      {:reply, {:error, %{reason: "not subscribed"}}, socket}
    end
  end

  def handle_in("heartbeat", %{"dm_key" => dm_key}, socket) do
    Chat.heartbeat(dm_key)
    {:noreply, socket}
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

  @impl true
  def terminate(_reason, socket) do
    Enum.each(socket.assigns.subscriptions, fn dm_key ->
      if dm_key == @broadcast_key do
        PubSub.unsubscribe(@pubsub, @broadcast_key)
      else
        PubSub.unsubscribe(@pubsub, "dm:" <> dm_key)
      end
    end)

    :ok
  end

  defp authorize_dm(dm_key, participant_id) do
    dm = DmKey.parse!(dm_key)

    if DmKey.includes?(dm, participant_id) do
      {:ok, dm}
    else
      {:error, :unauthorized}
    end
  rescue
    e in ArgumentError -> {:error, e}
  end
end
