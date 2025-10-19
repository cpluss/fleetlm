defmodule FleetlmWeb.SessionController do
  use FleetlmWeb, :controller

  alias Fleetlm.Runtime
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

  def create(conn, %{"user_id" => user_id, "agent_id" => agent_id} = params) do
    metadata = Map.get(params, "metadata", %{})

    case Storage.create_session(user_id, agent_id, metadata) do
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

  def create(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "user_id and agent_id are required"})
  end

  def messages(conn, %{"session_id" => session_id} = params) do
    last_seq = parse_int(params["after_seq"], 0)
    limit = parse_int(params["limit"], 50)

    # Check session exists
    case Fleetlm.Repo.get(Fleetlm.Storage.Model.Session, session_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Session not found"})

      _session ->
        # Get messages via Runtime API
        {:ok, messages} = Runtime.get_messages(session_id, last_seq, limit)
        formatted = Enum.map(messages, &render_message/1)
        json(conn, %{messages: formatted})
    end
  end

  def append_message(conn, %{"session_id" => session_id} = params) do
    with {:ok, sender_id} <- resolve_participant(params),
         {:ok, kind} <- resolve_kind(params),
         {:ok, content} <- require_map_param(params, "content"),
         {:ok, metadata} <- normalize_metadata(Map.get(params, "metadata", %{})),
         {:ok, session} <- load_session(session_id) do
      # Determine recipient (flip between user and agent)
      recipient_id =
        if sender_id == session.user_id, do: session.agent_id, else: session.user_id

      case Runtime.append_message(session_id, sender_id, recipient_id, kind, content, metadata) do
        {:ok, seq} ->
          message = %{
            id: Uniq.UUID.uuid7(:slug),
            session_id: session_id,
            seq: seq,
            sender_id: sender_id,
            kind: kind,
            content: content,
            metadata: metadata,
            inserted_at: NaiveDateTime.utc_now()
          }

          json(conn, %{message: render_message(message)})

        {:error, reason} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: inspect(reason)})

        {:timeout, _} ->
          conn
          |> put_status(:request_timeout)
          |> json(%{error: "Raft timeout"})
      end
    else
      {:error, %ArgumentError{} = error} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: Exception.message(error)})

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

  def append_message(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "session_id is required"})
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

  defp render_session(session) do
    user_id = Map.get(session, :user_id)
    agent_id = Map.get(session, :agent_id)
    metadata = session.metadata || %{}

    %{
      id: session.id,
      user_id: user_id,
      agent_id: agent_id,
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
      seq: Map.get(message, :seq) || Map.get(message, "seq"),
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

  defp resolve_participant(%{"user_id" => _user_id, "agent_id" => _}) do
    {:error,
     %ArgumentError{
       message: "Provide either user_id or agent_id when sending a message, not both"
     }}
  end

  defp resolve_participant(%{"user_id" => user_id})
       when is_binary(user_id) and byte_size(user_id) > 0 do
    {:ok, user_id}
  end

  defp resolve_participant(%{"agent_id" => agent_id})
       when is_binary(agent_id) and byte_size(agent_id) > 0 do
    {:ok, agent_id}
  end

  defp resolve_participant(%{"sender_id" => _}) do
    {:error,
     %ArgumentError{
       message: "sender_id is deprecated; use user_id or agent_id to identify the sender"
     }}
  end

  defp resolve_participant(_),
    do: {:error, %ArgumentError{message: "user_id or agent_id is required"}}

  defp resolve_kind(%{"kind" => kind}) when is_binary(kind) and byte_size(kind) > 0,
    do: {:ok, kind}

  defp resolve_kind(%{"kind" => _}),
    do: {:error, %ArgumentError{message: "kind must be a non-empty string"}}

  defp resolve_kind(_), do: {:ok, "text"}

  defp require_map_param(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _} -> {:error, %ArgumentError{message: "#{key} must be a map"}}
      :error -> {:error, %ArgumentError{message: "#{key} is required"}}
    end
  end

  defp normalize_metadata(value) when is_map(value), do: {:ok, value}

  defp normalize_metadata(_),
    do: {:error, %ArgumentError{message: "metadata must be a map"}}

  defp session_user_id(%{user_id: user_id}) when is_binary(user_id) and byte_size(user_id) > 0,
    do: {:ok, user_id}

  defp session_user_id(_), do: {:error, :missing_user}

  defp load_session(session_id) do
    case Fleetlm.Repo.get(Fleetlm.Storage.Model.Session, session_id) do
      nil -> {:error, :not_found}
      session -> {:ok, session}
    end
  end
end
