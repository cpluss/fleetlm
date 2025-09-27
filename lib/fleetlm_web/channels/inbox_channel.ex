defmodule FleetlmWeb.InboxChannel do
  @moduledoc """
  Channel streaming inbox snapshots for a participant.
  """

  use FleetlmWeb, :channel

  alias Fleetlm.Sessions
  alias Fleetlm.Sessions.InboxSupervisor
  alias Fleetlm.Sessions.Cache

  @impl true
  def join(
        "inbox:" <> participant_id,
        _params,
        %{assigns: %{participant_id: participant_id}} = socket
      ) do
    with {:ok, _pid} <- InboxSupervisor.ensure_started(participant_id) do
      snapshot = load_snapshot(participant_id)
      Phoenix.PubSub.subscribe(Fleetlm.PubSub, "inbox:" <> participant_id)
      {:ok, %{conversations: snapshot}, assign(socket, :participant_id, participant_id)}
    else
      {:error, reason} -> {:error, %{reason: inspect(reason)}}
    end
  end

  def join("inbox:" <> _other, _params, _socket), do: {:error, %{reason: "unauthorized"}}

  @impl true
  def handle_info({:inbox_snapshot, snapshot}, socket) do
    push(socket, "snapshot", %{conversations: snapshot})
    {:noreply, socket}
  end

  defp load_snapshot(participant_id) do
    case Cache.fetch_inbox_snapshot(participant_id) do
      {:ok, snapshot} ->
        snapshot

      _ ->
        Sessions.list_sessions_for_participant(participant_id)
        |> Enum.map(fn session ->
          %{
            "session_id" => session.id,
            "kind" => session.kind,
            "status" => session.status,
            "last_message_id" => session.last_message_id,
            "last_message_at" => encode_datetime(session.last_message_at),
            "agent_id" => session.agent_id,
            "initiator_id" => session.initiator_id,
            "peer_id" => session.peer_id
          }
        end)
    end
  end

  defp encode_datetime(nil), do: nil
  defp encode_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp encode_datetime(%NaiveDateTime{} = naive), do: NaiveDateTime.to_iso8601(naive)
end
