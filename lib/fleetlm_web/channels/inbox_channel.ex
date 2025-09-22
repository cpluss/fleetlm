defmodule FleetlmWeb.InboxChannel do
  @moduledoc """
  The InboxChannel is used to subscribe to the inbox notifications of a participant, in order to receive
  live updates when new messages are sent. This allows the client to maintain the conversation state
  without consuming every single message it may not necessarily care about.

  This allows our chat mechanism to scale to a large number of participants, as one client can choose which
  participants to engage with scalably.
  """
  use FleetlmWeb, :channel

  alias Fleetlm.Chat
  alias Fleetlm.Chat.Dispatcher
  alias Fleetlm.Chat.Event
  alias Phoenix.PubSub

  @pubsub Fleetlm.PubSub

  @impl true
  def join("inbox:" <> participant_id, _params, socket) do
    if participant_id == socket.assigns.participant_id do
      case Dispatcher.ensure_inbox(participant_id) do
        {:ok, _pid} ->
          :ok = PubSub.subscribe(@pubsub, "participant:" <> participant_id)

          inbox =
            participant_id
            |> Chat.inbox_snapshot()
            |> Enum.map(&Event.DmActivity.to_payload/1)

          {:ok, %{"conversations" => inbox}, socket}

        {:error, reason} ->
          {:error, %{reason: inspect(reason)}}
      end
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_in("heartbeat", _payload, socket) do
    Dispatcher.heartbeat_inbox(socket.assigns.participant_id)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:dm_activity, metadata}, socket) do
    payload = normalise_activity_payload(metadata)
    push(socket, "tick", %{"updates" => [payload]})
    {:noreply, socket}
  end

  defp normalise_activity_payload(%Event.DmActivity{} = event),
    do: Event.DmActivity.to_payload(event)

  defp normalise_activity_payload(%{} = payload), do: payload
end
