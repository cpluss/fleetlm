defmodule FleetlmWeb.InboxChannel do
  @moduledoc """
  The InboxChannel is used to subscribe to the inbox notifications of a participant, in order to receive
  live updates when new messages are sent. This allows the client to maintain the conversation state
  without consuming every single message it may not necessarily care about.

  This allows our chat mechanism to scale to a large number of participants, as one client can choose which
  participants to engage with scalably.
  """
  use FleetlmWeb, :channel

  alias Fleetlm.Chat.InboxServer
  alias Fleetlm.Chat.InboxSupervisor
  alias Phoenix.PubSub

  @pubsub Fleetlm.PubSub

  @impl true
  def join("inbox:" <> participant_id, _params, socket) do
    if participant_id == socket.assigns.participant_id do
      with {:ok, _pid} <- InboxSupervisor.ensure_started(participant_id),
           {:ok, snapshot} <- InboxServer.snapshot(participant_id) do
        :ok = PubSub.subscribe(@pubsub, inbox_topic(participant_id))
        response = %{"conversations" => snapshot}
        {:ok, response, assign(socket, :participant_id, participant_id)}
      else
        {:error, reason} -> {:error, %{reason: inspect(reason)}}
      end
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_in("heartbeat", _payload, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info({:inbox_delta, %{updates: updates}}, socket) do
    push(socket, "tick", %{"updates" => updates})
    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp inbox_topic(participant_id), do: "inbox:" <> participant_id
end
