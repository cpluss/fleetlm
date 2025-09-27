defmodule Fleetlm.Runtime.Events do
  @moduledoc """
  PubSub fan-out helpers for session messages and inbox updates.

  `SessionServer` delegates to this module to broadcast real-time payloads to
  LiveView/Channel subscribers (`"session:" <> id`) and to nudge inbox
  projections. This keeps the runtime logic small and provides a single place
  to shape payloads sent to clients.
  """

  alias Fleetlm.Observability
  alias Fleetlm.Conversation
  alias Fleetlm.Runtime.InboxServer

  @pubsub Fleetlm.PubSub

  def publish_message(%{session_id: session_id} = message) do
    payload = message_payload(message)
    topic = "session:" <> session_id

    {_pubsub_result, pubsub_duration} =
      measure_duration_us(fn ->
        Phoenix.PubSub.broadcast(@pubsub, topic, {:session_message, payload})
      end)

    Observability.record_session_fanout(session_id, :pubsub, pubsub_duration, %{topic: topic})
    Observability.emit_pubsub_broadcast(topic, :session_message, pubsub_duration)

    {participant_count, inbox_duration} = notify_inboxes(message)

    Observability.record_session_fanout(session_id, :inbox, inbox_duration, %{
      participant_count: participant_count || 0
    })

    :ok
  end

  defp notify_inboxes(message) do
    case Map.get(message, :session) do
      nil ->
        {0, 0}

      session ->
        session = ensure_participants(session)
        participants = [session.initiator_id, session.peer_id]

        {_result, duration_us} =
          measure_duration_us(fn ->
            Enum.each(participants, fn participant_id ->
              case GenServer.whereis(InboxServer.via(participant_id)) do
                pid when is_pid(pid) ->
                  InboxServer.enqueue_update(participant_id, session, message)

                nil ->
                  :noop
              end
            end)
          end)

        {length(participants), duration_us}
    end
  end

  defp message_payload(message) do
    content = stringify_map(Map.get(message, :content))
    metadata = stringify_map(Map.get(message, :metadata))

    %{
      "id" => Map.get(message, :id),
      "session_id" => Map.get(message, :session_id),
      "kind" => Map.get(message, :kind),
      "content" => content,
      "metadata" => metadata,
      "sender_id" => Map.get(message, :sender_id),
      "inserted_at" => encode_datetime(Map.get(message, :inserted_at))
    }
  end

  defp encode_datetime(%NaiveDateTime{} = naive), do: NaiveDateTime.to_iso8601(naive)
  defp encode_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp encode_datetime(nil), do: nil

  defp stringify_map(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> {to_string(k), v} end)
    |> Enum.into(%{})
  end

  defp stringify_map(_), do: %{}

  defp measure_duration_us(fun) when is_function(fun, 0) do
    start = System.monotonic_time()
    result = fun.()
    duration = System.monotonic_time() - start
    duration_us = System.convert_time_unit(duration, :native, :microsecond)

    {result, duration_us}
  end

  defp ensure_participants(%{initiator_id: initiator_id, peer_id: peer_id} = session)
       when not is_nil(initiator_id) and not is_nil(peer_id) do
    session
  end

  defp ensure_participants(%{id: session_id} = session) do
    full_session = Conversation.get_session!(session_id)

    session
    |> Map.put(:initiator_id, full_session.initiator_id)
    |> Map.put(:peer_id, full_session.peer_id)
  end

  defp ensure_participants(session), do: session
end
