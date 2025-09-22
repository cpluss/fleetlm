defmodule FleetlmWeb.ParticipantChannel do
  use FleetlmWeb, :channel

  alias Fleetlm.Chat
  alias Fleetlm.Chat.Event
  alias Phoenix.PubSub

  @pubsub Fleetlm.PubSub

  @impl true
  def join("participant:" <> participant_id, _params, socket) do
    if participant_id == socket.assigns.participant_id do
      :ok = PubSub.subscribe(@pubsub, "participant:" <> participant_id)

      inbox =
        participant_id
        |> Chat.inbox_snapshot()
        |> Enum.map(&Event.DmActivity.to_payload/1)

      {:ok, %{"dm_threads" => inbox}, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_in(
        "dm:create",
        %{"participant_id" => other_participant_id, "message" => message},
        socket
      ) do
    current_participant_id = socket.assigns.participant_id

    case Chat.create_dm(current_participant_id, other_participant_id, message) do
      {:ok, %{dm_key: dm_key}} ->
        {:reply, {:ok, %{"dm_key" => dm_key, "thread_id" => dm_key}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{"reason" => "failed to create DM: #{inspect(reason)}"}}, socket}
    end
  end

  @impl true
  def handle_info({:dm_activity, metadata}, socket) do
    payload =
      metadata
      |> normalise_activity_payload()

    push(socket, "tick", %{"updates" => [payload]})
    {:noreply, socket}
  end

  defp normalise_activity_payload(%Event.DmActivity{} = event),
    do: Event.DmActivity.to_payload(event)

  defp normalise_activity_payload(%{} = payload), do: payload
end
