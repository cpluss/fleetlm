defmodule FleetlmWeb.SessionChannel do
  @moduledoc """
  Socket channel for streaming messages within a session.
  """

  use FleetlmWeb, :channel

  alias Fleetlm.Runtime.Router
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
        case Router.join(session_id, user_id, last_seq: last_seq, limit: 100) do
          {:ok, result} ->
            response = %{session_id: session_id, messages: result.messages}
            {:ok, response, assign(socket, :session, session)}

          {:error, :not_found} ->
            {:error, %{reason: "not found"}}

          {:error, :unauthorized} ->
            {:error, %{reason: "unauthorized"}}

          {:error, reason} ->
            {:error, %{reason: inspect(reason)}}
        end

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
    case Router.append_message(session.id, user_id, kind, content, metadata) do
      {:ok, message} ->
        {:reply, {:ok, %{seq: message.seq}}, socket}

      {:error, :draining} ->
        push(socket, "backpressure", %{
          reason: "session_draining",
          retry_after_ms: 1000
        })

        {:noreply, socket}

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
