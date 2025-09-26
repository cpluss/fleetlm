defmodule FleetlmWeb.SessionChannel do
  @moduledoc """
  Socket channel for streaming messages within a session.
  """

  use FleetlmWeb, :channel

  alias Fleetlm.Sessions
  alias Fleetlm.Sessions.SessionServer

  @impl true
  def join(
        "session:" <> session_id,
        _params,
        %{assigns: %{participant_id: participant_id}} = socket
      ) do
    with {:ok, session} <- authorize(session_id, participant_id),
         {:ok, tail} <- SessionServer.load_tail(session_id) do
      Phoenix.PubSub.subscribe(Fleetlm.PubSub, "session:" <> session_id)

      messages = Enum.map(tail, &payload_with_iso/1)
      response = %{session_id: session_id, messages: messages}

      {:ok, response, assign(socket, :session, session)}
    else
      {:error, reason} -> {:error, %{reason: error_reason(reason)}}
    end
  end

  @impl true
  def handle_info({:session_message, payload}, socket) do
    push(socket, "message", payload)
    {:noreply, socket}
  end

  @impl true
  def handle_in(
        "send",
        %{"content" => content},
        %{assigns: %{session: session, participant_id: participant_id}} = socket
      ) do
    attrs = %{
      sender_id: participant_id,
      kind: Map.get(content, "kind", "text"),
      content: Map.get(content, "content", %{}),
      metadata: Map.get(content, "metadata", %{})
    }

    case Sessions.append_message(session.id, attrs) do
      {:ok, _message} -> {:noreply, socket}
      {:error, reason} -> {:reply, {:error, %{error: inspect(reason)}}, socket}
    end
  end

  defp authorize(session_id, participant_id) do
    session = Sessions.get_session!(session_id)

    if participant_id in [session.initiator_id, session.peer_id] do
      {:ok, session}
    else
      {:error, :unauthorized}
    end
  rescue
    _ -> {:error, :not_found}
  end

  defp error_reason(:unauthorized), do: "unauthorized"
  defp error_reason(:not_found), do: "not found"
  defp error_reason(other), do: inspect(other)

  defp payload_with_iso(message) do
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

  defp encode_datetime(nil), do: nil
  defp encode_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp encode_datetime(%NaiveDateTime{} = naive), do: NaiveDateTime.to_iso8601(naive)
end
