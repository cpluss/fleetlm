defmodule FleetlmWeb.ConversationChannel do
  @moduledoc """
  Per-conversation channel responsible for streaming direct messages or broadcast updates to
  authorized participants.
  """

  use FleetlmWeb, :channel

  alias Fleetlm.Chat
  alias Fleetlm.Chat.{DmKey, Events}
  @history_limit 40
  @broadcast_key "broadcast"

  @impl true
  def join("conversation:" <> topic_key, _params, socket) do
    participant_id = socket.assigns.participant_id

    result =
      case topic_key do
        @broadcast_key -> join_broadcast(socket)
        dm_key -> join_dm(dm_key, participant_id, socket)
      end

    case result do
      {:ok, response, new_socket} ->
        {:ok, response, new_socket}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def handle_in("heartbeat", _payload, %{assigns: %{dm_key: dm_key}} = socket) do
    if dm_key not in [nil, @broadcast_key], do: Chat.heartbeat(dm_key)
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

  defp join_dm(dm_key, participant_id, socket) do
    with {:ok, dm} <- authorize_dm(dm_key, participant_id),
         {:ok, events} <- Chat.get_messages(dm.key, limit: @history_limit) do
      history = Enum.map(events, &Events.DmMessage.to_payload/1)
      {:ok, %{"dm_key" => dm.key, "messages" => history}, assign(socket, :dm_key, dm.key)}
    else
      {:error, reason} ->
        {:error, %{reason: inspect(reason)}}
    end
  end

  defp join_broadcast(socket) do
    :ok = Phoenix.PubSub.subscribe(Fleetlm.PubSub, @broadcast_key)

    history =
      Chat.list_broadcast_messages(limit: @history_limit)
      |> Enum.reverse()
      |> Enum.map(&Events.BroadcastMessage.to_payload/1)

    response = %{"dm_key" => @broadcast_key, "messages" => history}
    {:ok, response, assign(socket, :dm_key, @broadcast_key)}
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
