defmodule FleetlmWeb.InboxChannel do
  @moduledoc """
  Channel streaming inbox deltas / notifications for a participant.
  """

  use FleetlmWeb, :channel

  alias Fleetlm.Runtime.{InboxSupervisor, InboxServer}

  @impl true
  def join("inbox:" <> participant_id, _params, %{assigns: %{participant_id: participant_id}} = socket) do
    with {:ok, _pid} <- InboxSupervisor.ensure_started(participant_id) do
      {:ok, snapshot} = InboxServer.get_snapshot(participant_id)

      {:ok, %{inbox: snapshot}, assign(socket, :participant_id, participant_id)}
    else
      {:error, reason} -> {:error, %{reason: inspect(reason)}}
    end
  end

  @impl true
  def handle_info({:inbox_snapshot, snapshot}, socket) do
    push(socket, "inbox_delta", %{inbox: snapshot})
    {:noreply, socket}
  end
end
