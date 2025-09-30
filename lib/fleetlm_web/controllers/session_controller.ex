defmodule FleetlmWeb.SessionController do
  use FleetlmWeb, :controller

  alias Fleetlm.Runtime.Router
  alias FleetLM.Storage.API, as: StorageAPI

  action_fallback FleetlmWeb.FallbackController

  def create(conn, params) do
    sender_id = Map.get(params, "initiator_id") || Map.get(params, "sender_id")
    recipient_id = Map.get(params, "peer_id") || Map.get(params, "recipient_id")
    metadata = Map.get(params, "metadata", %{})

    case StorageAPI.create_session(sender_id, recipient_id, metadata) do
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
    case Fleetlm.Repo.get(FleetLM.Storage.Model.Session, session_id) do
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

  def append_message(conn, %{"session_id" => session_id} = params) do
    sender_id = Map.get(params, "sender_id")
    kind = Map.get(params, "kind", "text")
    content = Map.get(params, "content", %{})
    metadata = Map.get(params, "metadata", %{})

    case Router.append_message(session_id, sender_id, kind, content, metadata) do
      {:ok, message} ->
        json(conn, %{message: render_message(message)})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(reason)})
    end
  end

  def mark_read(conn, %{"session_id" => session_id} = params) do
    with {:ok, participant_id} <- require_param(params, "participant_id"),
         last_seq <- parse_int(params["last_seq"], 0),
         {:ok, _cursor} <- StorageAPI.update_cursor(session_id, participant_id, last_seq) do
      session = Fleetlm.Repo.get(FleetLM.Storage.Model.Session, session_id)

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
    case StorageAPI.archive_session(session_id) do
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
    %{
      id: session.id,
      # Map new field names to old API for backward compatibility
      initiator_id: session.sender_id,
      peer_id: session.recipient_id,
      sender_id: session.sender_id,
      recipient_id: session.recipient_id,
      status: session.status,
      metadata: session.metadata || %{},
      inserted_at: encode_datetime(session.inserted_at),
      updated_at: encode_datetime(session.updated_at)
    }
  end

  defp render_message(%{} = message) when is_map(message) do
    # Handle both struct and map formats
    content = stringify_map(get_field(message, :content))
    metadata = stringify_map(get_field(message, :metadata))

    %{
      id: get_field(message, :id),
      session_id: get_field(message, :session_id),
      sender_id: get_field(message, :sender_id),
      kind: get_field(message, :kind),
      content: content,
      metadata: metadata,
      inserted_at: encode_datetime(get_field(message, :inserted_at))
    }
  end

  defp get_field(%{} = map, key) do
    Map.get(map, key) || Map.get(map, to_string(key))
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
