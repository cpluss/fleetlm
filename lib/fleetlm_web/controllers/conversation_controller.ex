defmodule FleetlmWeb.ConversationController do
  use FleetlmWeb, :controller

  alias Fleetlm.Chat
  alias Fleetlm.Chat.{DmKey, Event}

  @broadcast_key "broadcast"

  def index(conn, %{"dm_key" => dm_key} = params) do
    participant_id = params["participant_id"]
    limit = params["limit"] || 40

    with {:ok, limit} <- parse_limit(limit),
         {:ok, messages} <- fetch_messages(dm_key, participant_id, limit) do
      json(conn, %{
        "dm_key" => dm_key,
        "messages" => messages
      })
    else
      {:error, reason} -> render_error(conn, reason)
    end
  end

  def create(conn, %{"dm_key" => dm_key} = params) do
    sender_id = params["sender_id"]
    metadata = params["metadata"] || %{}
    text = params["text"]

    with {:ok, payload} <- deliver_message(dm_key, sender_id, text, metadata) do
      json(conn, payload)
    else
      {:error, reason} -> render_error(conn, reason)
    end
  end

  defp fetch_messages(@broadcast_key, _participant_id, limit) do
    messages =
      Chat.list_broadcast_messages(limit: limit)
      |> Enum.map(&Event.BroadcastMessage.to_payload/1)

    {:ok, messages}
  end

  defp fetch_messages(_dm_key, nil, _limit), do: {:error, :missing_participant}

  defp fetch_messages(dm_key, participant_id, limit) do
    with {:ok, dm} <- authorize(dm_key, participant_id),
         {:ok, events} <- Chat.get_messages(dm.key, limit: limit) do
      {:ok, Enum.map(events, &Event.DmMessage.to_payload/1)}
    end
  end

  defp deliver_message(@broadcast_key, sender_id, text, metadata) when is_binary(sender_id) do
    case Chat.send_broadcast_message(sender_id, text, metadata) do
      {:ok, event} -> {:ok, Event.BroadcastMessage.to_payload(event)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp deliver_message(dm_key, sender_id, text, metadata)
       when is_binary(sender_id) do
    with {:ok, dm} <- authorize(dm_key, sender_id),
         recipient <- DmKey.other_participant(dm, sender_id),
         {:ok, event} <-
           Chat.send_message(%{
             dm_key: dm.key,
             sender_id: sender_id,
             recipient_id: recipient,
             text: text,
             metadata: metadata
           }) do
      {:ok, Event.DmMessage.to_payload(event)}
    end
  end

  defp authorize(@broadcast_key, _participant_id), do: {:ok, :broadcast}

  defp authorize(dm_key, participant_id) do
    dm = DmKey.parse!(dm_key)

    if DmKey.includes?(dm, participant_id) do
      {:ok, dm}
    else
      {:error, :unauthorized}
    end
  rescue
    e in ArgumentError -> {:error, e}
  end

  defp parse_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {int, _} when int > 0 -> {:ok, int}
      _ -> {:error, :invalid_limit}
    end
  end

  defp parse_limit(limit) when is_integer(limit) and limit > 0, do: {:ok, limit}
  defp parse_limit(nil), do: {:ok, 40}
  defp parse_limit(_), do: {:error, :invalid_limit}

  defp render_error(conn, :unauthorized) do
    conn
    |> put_status(:forbidden)
    |> json(%{"error" => "unauthorized"})
  end

  defp render_error(conn, :missing_participant) do
    conn
    |> put_status(:bad_request)
    |> json(%{"error" => "participant_id required"})
  end

  defp render_error(conn, :invalid_limit) do
    conn
    |> put_status(:bad_request)
    |> json(%{"error" => "invalid limit"})
  end

  defp render_error(conn, %ArgumentError{message: message}) do
    conn
    |> put_status(:bad_request)
    |> json(%{"error" => message})
  end

  defp render_error(conn, reason) do
    conn
    |> put_status(:bad_request)
    |> json(%{"error" => inspect(reason)})
  end
end
