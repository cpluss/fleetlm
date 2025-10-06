defmodule FleetlmWeb.SessionController do
  use FleetlmWeb, :controller

  alias Fleetlm.Runtime.Router
  alias Fleetlm.Storage

  action_fallback FleetlmWeb.FallbackController

  def index(conn, params) do
    import Ecto.Query

    query =
      case Map.get(params, "user_id") do
        nil ->
          Fleetlm.Storage.Model.Session

        user_id when is_binary(user_id) ->
          from(s in Fleetlm.Storage.Model.Session, where: s.user_id == ^user_id)
      end

    sessions =
      query
      |> order_by([s], desc: s.inserted_at)
      |> limit(50)
      |> Fleetlm.Repo.all()

    json(conn, %{sessions: Enum.map(sessions, &render_session/1)})
  end

  def show(conn, %{"id" => session_id}) do
    case Storage.get_session(session_id) do
      {:ok, session} ->
        json(conn, %{session: render_session(session)})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Session not found"})
    end
  end

  # New API with sender_id/recipient_id
  def create(conn, %{"sender_id" => sender_id, "recipient_id" => recipient_id} = params) do
    metadata = Map.get(params, "metadata", %{})

    case Storage.create_session(sender_id, recipient_id, metadata) do
      {:ok, session} ->
        conn
        |> put_status(:created)
        |> json(%{session: render_session(session)})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(reason)})
    end
  end

  def messages(conn, %{"session_id" => session_id} = params) do
    last_seq = parse_int(params["after_seq"], 0)
    limit = parse_int(params["limit"], 50)

    # Get first participant from session to use for join (required for authorization)
    case Fleetlm.Repo.get(Fleetlm.Storage.Model.Session, session_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Session not found"})

      session ->
        case Router.join(session_id, session.sender_id, last_seq: last_seq, limit: limit) do
          {:ok, result} ->
            json(conn, %{messages: result.messages})

          {:error, reason} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: inspect(reason)})
        end
    end
  end

  # Full message with all fields
  def append_message(
        conn,
        %{
          "session_id" => session_id,
          "sender_id" => sender_id,
          "kind" => kind,
          "content" => content,
          "metadata" => metadata
        }
      ) do
    case Router.append_message(session_id, sender_id, kind, content, metadata) do
      {:ok, message} ->
        json(conn, %{message: render_message(message)})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(reason)})
    end
  end

  # Message with sender, kind, and content (metadata defaults to %{})
  def append_message(
        conn,
        %{
          "session_id" => session_id,
          "sender_id" => sender_id,
          "kind" => kind,
          "content" => content
        }
      ) do
    case Router.append_message(session_id, sender_id, kind, content, %{}) do
      {:ok, message} ->
        json(conn, %{message: render_message(message)})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(reason)})
    end
  end

  # Message with sender and content only (kind defaults to "text", metadata to %{})
  def append_message(conn, %{
        "session_id" => session_id,
        "sender_id" => sender_id,
        "content" => content
      }) do
    case Router.append_message(session_id, sender_id, "text", content, %{}) do
      {:ok, message} ->
        json(conn, %{message: render_message(message)})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(reason)})
    end
  end

  def mark_read(conn, %{"session_id" => session_id} = params) do
    with {:ok, user_id} <- require_param(params, "user_id"),
         last_seq <- parse_int(params["last_seq"], 0),
         {:ok, _cursor} <- Storage.update_cursor(session_id, user_id, last_seq) do
      session = Fleetlm.Repo.get(Fleetlm.Storage.Model.Session, session_id)

      if session do
        json(conn, %{session: render_session(session)})
      else
        conn
        |> put_status(:not_found)
        |> json(%{error: "Session not found"})
      end
    else
      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(reason)})
    end
  end

  def delete(conn, %{"session_id" => session_id}) do
    case Storage.archive_session(session_id) do
      {:ok, _session} ->
        send_resp(conn, :no_content, "")

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Session not found"})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(reason)})
    end
  end

  defp render_session(%{metadata: nil} = session) do
    %{
      id: session.id,
      # Map new field names to old API for backward compatibility
      initiator_id: session.sender_id,
      peer_id: session.recipient_id,
      sender_id: session.sender_id,
      recipient_id: session.recipient_id,
      status: session.status,
      metadata: %{},
      inserted_at: encode_datetime(session.inserted_at),
      updated_at: encode_datetime(session.updated_at)
    }
  end

  defp render_session(%{metadata: metadata} = session) do
    %{
      id: session.id,
      # Map user_id/agent_id to API field names for backward compatibility
      initiator_id: session.user_id,
      peer_id: session.agent_id,
      sender_id: session.user_id,
      recipient_id: session.agent_id,
      user_id: session.user_id,
      agent_id: session.agent_id,
      status: session.status,
      metadata: metadata,
      inserted_at: encode_datetime(session.inserted_at),
      updated_at: encode_datetime(session.updated_at)
    }
  end

  defp render_message(%{} = message) when is_map(message) do
    %{
      id: message.id,
      session_id: message.session_id,
      sender_id: message.sender_id,
      kind: message.kind,
      content: message.content,
      metadata: message.metadata,
      inserted_at: encode_datetime(message.inserted_at)
    }
  end

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
