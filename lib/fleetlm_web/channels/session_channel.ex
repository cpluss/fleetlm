defmodule FleetlmWeb.SessionChannel do
  @moduledoc """
  Socket channel for streaming messages within a session.
  """

  use FleetlmWeb, :channel

  alias Fleetlm.Runtime
  alias Fleetlm.Storage.Model.Session

  @impl true
  def join(
        "session:" <> session_id,
        params,
        %{assigns: %{user_id: user_id}} = socket
      ) do
    last_seq = parse_last_seq(Map.get(params, "last_seq"))

    case authorize(session_id, user_id) do
      {:ok, session} ->
        # Get messages via Runtime API
        {:ok, messages} = Runtime.get_messages(session_id, last_seq, 100)
        formatted = Enum.map(messages, &format_message/1)

        response = %{session_id: session_id, messages: formatted}
        {:ok, response, assign(socket, :session, session)}

      {:error, :not_found} ->
        {:error, %{reason: "not found"}}

      {:error, :unauthorized} ->
        {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_info({:session_message, payload}, socket) do
    push(socket, "message", payload)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:session_stream_chunk, payload}, socket) do
    push(socket, "stream_chunk", payload)
    {:noreply, socket}
  end

  # Full message with all fields
  @impl true
  def handle_in(
        "send",
        %{
          "content" => %{
            "kind" => kind,
            "content" => message_content,
            "metadata" => metadata
          }
        },
        %{assigns: %{session: session, user_id: user_id}} = socket
      )
      when is_binary(kind) and is_map(message_content) and is_map(metadata) do
    do_send_message(socket, session, user_id, kind, message_content, metadata)
  end

  # Message with content and kind only (metadata defaults to %{})
  @impl true
  def handle_in(
        "send",
        %{"content" => %{"kind" => kind, "content" => message_content}},
        %{assigns: %{session: session, user_id: user_id}} = socket
      )
      when is_binary(kind) and is_map(message_content) do
    do_send_message(socket, session, user_id, kind, message_content, %{})
  end

  # Message with only content (kind defaults to "text", metadata to %{})
  @impl true
  def handle_in(
        "send",
        %{"content" => %{"content" => message_content}},
        %{assigns: %{session: session, user_id: user_id}} = socket
      )
      when is_map(message_content) do
    do_send_message(socket, session, user_id, "text", message_content, %{})
  end

  # Catch-all for malformed messages
  @impl true
  def handle_in("send", payload, %{assigns: %{session: session}} = socket) do
    # Emit telemetry - CRITICAL data integrity tracking
    Fleetlm.Observability.Telemetry.emit_agent_validation_error(
      session.agent_id,
      session.id,
      :invalid_message_format
    )

    {:reply,
     {:error,
      %{
        error: "invalid_message_format",
        details: "content must be a map, metadata must be a map",
        received: inspect(payload)
      }}, socket}
  end

  defp do_send_message(socket, session, user_id, kind, content, metadata) do
    # TTFT tracking moved to FSM/Worker (no longer tracked here)

    # Determine recipient (flip between user and agent)
    recipient_id =
      if user_id == session.user_id, do: session.agent_id, else: session.user_id

    # Append via Runtime API (calls Raft internally)
    case Runtime.append_message(session.id, user_id, recipient_id, kind, content, metadata) do
      {:ok, seq} ->
        # Success! Message committed to quorum

        # Broadcast to session channel (for active session participants)
        message = %{
          "id" => Uniq.UUID.uuid7(:slug),
          "session_id" => session.id,
          "seq" => seq,
          "sender_id" => user_id,
          "kind" => kind,
          "content" => content,
          "metadata" => metadata,
          "inserted_at" => NaiveDateTime.to_iso8601(NaiveDateTime.utc_now())
        }

        Phoenix.PubSub.broadcast(
          Fleetlm.PubSub,
          "session:#{session.id}",
          {:session_message, message}
        )

        # Broadcast notification to user's inbox
        notification = %{
          "session_id" => session.id,
          "user_id" => session.user_id,
          "agent_id" => session.agent_id,
          "message_sender" => user_id,
          "timestamp" => message["inserted_at"]
        }

        Phoenix.PubSub.broadcast(
          Fleetlm.PubSub,
          "user:#{session.user_id}:inbox",
          {:message_notification, notification}
        )

        # Agent dispatch is now handled by RaftFSM effects (no longer called from here)

        {:reply, {:ok, %{seq: seq}}, socket}

      {:timeout, _leader} ->
        {:reply, {:error, %{error: "timeout"}}, socket}

      {:error, reason} ->
        {:reply, {:error, %{error: inspect(reason)}}, socket}
    end
  end

  defp authorize(session_id, user_id) do
    case Fleetlm.Repo.get(Session, session_id) do
      nil ->
        {:error, :not_found}

      %Session{user_id: session_user_id, agent_id: agent_id} = session
      when user_id in [session_user_id, agent_id] ->
        {:ok, session}

      %Session{} ->
        {:error, :unauthorized}
    end
  end

  # Format message for JSON response (handles both Raft and DB messages)
  defp format_message(%_{} = message) do
    # DB message (struct)
    %{
      "id" => message.id,
      "session_id" => message.session_id,
      "seq" => message.seq,
      "sender_id" => message.sender_id,
      "kind" => message.kind,
      "content" => message.content,
      "metadata" => message.metadata,
      "inserted_at" => encode_datetime(message.inserted_at)
    }
  end

  defp format_message(message) when is_map(message) do
    # Raft message (plain map)
    %{
      "id" => message.id,
      "session_id" => message.session_id,
      "seq" => message.seq,
      "sender_id" => message.sender_id,
      "kind" => message.kind,
      "content" => message.content,
      "metadata" => message.metadata,
      "inserted_at" => encode_datetime(message.inserted_at)
    }
  end

  defp encode_datetime(nil), do: nil
  defp encode_datetime(%NaiveDateTime{} = naive), do: NaiveDateTime.to_iso8601(naive)
  defp encode_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp parse_last_seq(nil), do: 0

  defp parse_last_seq(value) do
    value
    |> to_string()
    |> Integer.parse()
    |> case do
      {int, _} when int >= 0 -> int
      _ -> 0
    end
  end
end
