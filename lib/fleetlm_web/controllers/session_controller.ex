defmodule FleetlmWeb.SessionController do
  use FleetlmWeb, :controller

  alias Fleetlm.Runtime.Gateway
  alias Fleetlm.Sessions
  alias Fleetlm.Sessions.ChatMessage

  action_fallback FleetlmWeb.FallbackController

  def create(conn, params) do
    attrs = %{
      initiator_id: Map.get(params, "initiator_id"),
      peer_id: Map.get(params, "peer_id"),
      metadata: Map.get(params, "metadata", %{})
    }

    with {:ok, session} <- Sessions.start_session(attrs) do
      conn
      |> put_status(:created)
      |> json(%{session: render_session(session)})
    end
  end

  def messages(conn, %{"session_id" => session_id} = params) do
    after_id = Map.get(params, "after_id")
    limit = parse_int(params["limit"], 50)

    messages = Gateway.replay_messages(session_id, limit: limit, after_id: after_id)
    json(conn, %{messages: Enum.map(messages, &render_message/1)})
  end

  def append_message(conn, %{"session_id" => session_id} = params) do
    attrs = %{
      sender_id: Map.get(params, "sender_id"),
      kind: Map.get(params, "kind", "text"),
      content: Map.get(params, "content", %{}),
      metadata: Map.get(params, "metadata", %{})
    }

    with {:ok, %ChatMessage{} = message} <- Gateway.append_message(session_id, attrs) do
      json(conn, %{message: render_message(message)})
    end
  end

  def mark_read(conn, %{"session_id" => session_id} = params) do
    with {:ok, participant_id} <- require_param(params, "participant_id"),
         {:ok, session} <-
           Gateway.mark_read(session_id, participant_id,
             message_id: Map.get(params, "message_id")
           ) do
      json(conn, %{session: render_session(session)})
    end
  end

  defp render_session(session) do
    %{
      id: session.id,
      initiator_id: session.initiator_id,
      peer_id: session.peer_id,
      agent_id: session.agent_id,
      kind: session.kind,
      status: session.status,
      metadata: session.metadata,
      last_message_id: session.last_message_id,
      last_message_at: encode_datetime(session.last_message_at),
      initiator_last_read_id: session.initiator_last_read_id,
      initiator_last_read_at: encode_datetime(session.initiator_last_read_at),
      peer_last_read_id: session.peer_last_read_id,
      peer_last_read_at: encode_datetime(session.peer_last_read_at)
    }
  end

  defp render_message(message) do
    content = stringify_map(message.content)
    metadata = stringify_map(message.metadata)

    %{
      id: message.id,
      session_id: message.session_id,
      sender_id: message.sender_id,
      kind: message.kind,
      content: content,
      metadata: metadata,
      inserted_at: encode_datetime(message.inserted_at)
    }
  end

  defp stringify_map(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> {to_string(k), v} end)
    |> Enum.into(%{})
  end

  defp stringify_map(_), do: %{}

  defp encode_datetime(nil), do: nil
  defp encode_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp encode_datetime(%NaiveDateTime{} = naive), do: NaiveDateTime.to_iso8601(naive)

  defp parse_int(nil, default), do: default

  defp parse_int(value, default) do
    case Integer.parse(to_string(value)) do
      {int, _} when int > 0 -> int
      _ -> default
    end
  end

  defp require_param(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, %ArgumentError{message: "#{key} is required"}}
    end
  end
end
