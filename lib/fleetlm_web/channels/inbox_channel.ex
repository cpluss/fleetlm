defmodule FleetlmWeb.InboxChannel do
  @moduledoc """
  The InboxChannel is used to subscribe to the inbox notifications of a participant, in order to receive
  live updates when new messages are sent. This allows the client to maintain the conversation state
  without consuming every single message it may not necessarily care about.

  This allows our chat mechanism to scale to a large number of participants, as one client can choose which
  participants to engage with scalably.
  """
  use FleetlmWeb, :channel

  alias Phoenix.PubSub

  @pubsub Fleetlm.PubSub

  @impl true
  def join("inbox:" <> participant_id, _params, socket) do
    if participant_id == socket.assigns.participant_id do
      :ok = PubSub.subscribe(@pubsub, "participant:" <> participant_id)
      {:ok, %{"conversations" => []}, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_in("heartbeat", _payload, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info({:dm_activity, payload}, socket) do
    push(socket, "tick", %{"updates" => [payload]})
    {:noreply, socket}
  end
end
