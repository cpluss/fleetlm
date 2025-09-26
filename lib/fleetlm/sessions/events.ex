defmodule Fleetlm.Sessions.Events do
  @moduledoc """
  PubSub fan-out helpers for session messages and inbox updates.
  """

  alias Fleetlm.Sessions.InboxSupervisor
  alias Fleetlm.Sessions.InboxServer

  @pubsub Fleetlm.PubSub

  def publish_message(%{session_id: session_id} = message) do
    payload = message_payload(message)
    Phoenix.PubSub.broadcast(@pubsub, "session:" <> session_id, {:session_message, payload})

    notify_inboxes(message)
    :ok
  end

  defp notify_inboxes(message) do
    case Map.get(message, :session) do
      nil -> :ok
      session ->
        participants = [session.initiator_id, session.peer_id]

        Enum.each(participants, fn participant_id ->
          case InboxSupervisor.ensure_started(participant_id) do
            {:ok, _pid} -> InboxServer.enqueue_update(participant_id, session, message)
            {:error, _} -> :noop
          end
        end)
    end
  end

  defp message_payload(message) do
    %{
      "id" => Map.get(message, :id),
      "session_id" => Map.get(message, :session_id),
      "kind" => Map.get(message, :kind),
      "content" => Map.get(message, :content),
      "metadata" => Map.get(message, :metadata),
      "sender_id" => Map.get(message, :sender_id),
      "inserted_at" => encode_datetime(Map.get(message, :inserted_at))
    }
  end

  defp encode_datetime(%NaiveDateTime{} = naive), do: NaiveDateTime.to_iso8601(naive)
  defp encode_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp encode_datetime(nil), do: nil
end
