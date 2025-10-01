defmodule FleetlmWeb.InboxChannel do
  @moduledoc """
  Channel streaming inbox deltas / notifications for a user.
  """

  use FleetlmWeb, :channel

  alias Fleetlm.Runtime.{InboxSupervisor, InboxServer}

  @impl true
  def join("inbox:" <> user_id, _params, socket) do
    case InboxSupervisor.ensure_started(user_id) do
      {:ok, _pid} ->
        {:ok, snapshot} = InboxServer.get_snapshot(user_id)
        Phoenix.PubSub.subscribe(Fleetlm.PubSub, "inbox:user:#{user_id}")
        {:ok, %{inbox: snapshot}, assign(socket, :user_id, user_id)}

      {:error, reason} ->
        {:error, %{reason: inspect(reason)}}
    end
  end

  @impl true
  def handle_info({:inbox_snapshot, snapshot}, socket) do
    push(socket, "inbox_delta", %{inbox: snapshot})
    {:noreply, socket}
  end
end
