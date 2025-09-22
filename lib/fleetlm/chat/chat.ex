defmodule Fleetlm.Chat do
  import Ecto.Query, warn: false

  alias Fleetlm.Repo
  alias Fleetlm.Chat.{DmMessage, BroadcastMessage}

  @default_page_size 40
  @max_page_size 200

  ## DM Operations

  def send_dm_message(sender_id, recipient_id, text, metadata \\ %{}) do
    attrs = %{
      sender_id: sender_id,
      recipient_id: recipient_id,
      text: text,
      metadata: metadata
    }

    %DmMessage{}
    |> DmMessage.changeset(attrs)
    |> Repo.insert()
  end

  def get_dm_conversation(user_a_id, user_b_id, opts \\ []) do
    limit = limit_from_opts(opts)

    DmMessage
    |> where([m],
        (m.sender_id == ^user_a_id and m.recipient_id == ^user_b_id) or
        (m.sender_id == ^user_b_id and m.recipient_id == ^user_a_id)
      )
    |> order_by([m], desc: m.created_at)
    |> maybe_before(opts[:before])
    |> maybe_after(opts[:after])
    |> limit(^limit)
    |> Repo.all()
  end

  def get_dm_threads_for_user(user_id, opts \\ []) do
    limit = limit_from_opts(opts)

    # Get distinct conversations with last message timestamp
    query = """
    WITH conversations AS (
      SELECT
        CASE WHEN sender_id = $1 THEN recipient_id ELSE sender_id END as other_participant_id,
        created_at,
        text
      FROM dm_messages
      WHERE sender_id = $1 OR recipient_id = $1
    ),
    latest_messages AS (
      SELECT
        other_participant_id,
        MAX(created_at) as last_message_at
      FROM conversations
      GROUP BY other_participant_id
    )
    SELECT
      lm.other_participant_id,
      lm.last_message_at,
      c.text as last_message_text
    FROM latest_messages lm
    JOIN conversations c ON c.other_participant_id = lm.other_participant_id
                        AND c.created_at = lm.last_message_at
    ORDER BY lm.last_message_at DESC
    LIMIT $2
    """

    case Repo.query(query, [user_id, limit]) do
      {:ok, result} ->
        Enum.map(result.rows, fn [other_participant_id, last_message_at, last_message_text] ->
          %{
            other_participant_id: other_participant_id,
            last_message_at: last_message_at,
            last_message_text: last_message_text
          }
        end)

      {:error, _} ->
        []
    end
  end

  ## Broadcast Operations

  def send_broadcast_message(sender_id, text, metadata \\ %{}) do
    attrs = %{
      sender_id: sender_id,
      text: text,
      metadata: metadata
    }

    %BroadcastMessage{}
    |> BroadcastMessage.changeset(attrs)
    |> Repo.insert()
  end

  def list_broadcast_messages(opts \\ []) do
    limit = limit_from_opts(opts)

    BroadcastMessage
    |> order_by([m], desc: m.created_at)
    |> maybe_before_broadcast(opts[:before])
    |> maybe_after_broadcast(opts[:after])
    |> limit(^limit)
    |> Repo.all()
  end

  ## Message Dispatching (for ThreadServer compatibility)

  def dispatch_message(attrs, _opts \\ []) do
    case determine_message_type(attrs) do
      {:dm, sender_id, recipient_id} ->
        send_dm_message(sender_id, recipient_id, attrs[:text] || attrs["text"], attrs[:metadata] || attrs["metadata"] || %{})

      {:broadcast, sender_id} ->
        send_broadcast_message(sender_id, attrs[:text] || attrs["text"], attrs[:metadata] || attrs["metadata"] || %{})

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp determine_message_type(attrs) do
    sender_id = attrs[:sender_id] || attrs["sender_id"]
    recipient_id = attrs[:recipient_id] || attrs["recipient_id"]

    cond do
      sender_id && recipient_id ->
        {:dm, sender_id, recipient_id}

      sender_id && !recipient_id ->
        {:broadcast, sender_id}

      true ->
        {:error, "missing sender_id or invalid message type"}
    end
  end

  ## Helper functions

  defp maybe_before(query, nil), do: query
  defp maybe_before(query, cursor) do
    created_at = normalize_datetime!(cursor)
    where(query, [m], m.created_at < ^created_at)
  end

  defp maybe_after(query, nil), do: query
  defp maybe_after(query, cursor) do
    created_at = normalize_datetime!(cursor)
    where(query, [m], m.created_at > ^created_at)
  end

  defp maybe_before_broadcast(query, nil), do: query
  defp maybe_before_broadcast(query, cursor) do
    created_at = normalize_datetime!(cursor)
    where(query, [m], m.created_at < ^created_at)
  end

  defp maybe_after_broadcast(query, nil), do: query
  defp maybe_after_broadcast(query, cursor) do
    created_at = normalize_datetime!(cursor)
    where(query, [m], m.created_at > ^created_at)
  end

  defp normalize_datetime!(%DateTime{} = datetime) do
    DateTime.truncate(datetime, :microsecond)
  end

  defp normalize_datetime!(%NaiveDateTime{} = naive) do
    naive
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.truncate(:microsecond)
  end

  defp normalize_datetime!(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        DateTime.truncate(datetime, :microsecond)

      {:error, _} ->
        case NaiveDateTime.from_iso8601(value) do
          {:ok, naive} -> normalize_datetime!(naive)
          {:error, _} -> raise ArgumentError, "invalid datetime"
        end
    end
  end

  defp limit_from_opts(opts) do
    opts
    |> Keyword.get(:limit, @default_page_size)
    |> clamp_limit()
  end

  defp clamp_limit(limit) when is_integer(limit) and limit > 0 do
    min(limit, @max_page_size)
  end

  defp clamp_limit(_), do: @default_page_size

  ## Runtime helpers (simplified for new schema)

  def ensure_thread_runtime(_thread_id), do: :ok

  # Legacy compatibility for existing code
  def ensure_dm!(sender_id, recipient_id, _opts \\ []) do
    # Return a fake thread struct for compatibility
    %{id: dm_thread_id(sender_id, recipient_id), kind: "dm"}
  end

  def get_or_create_dm!(sender_id, recipient_id), do: ensure_dm!(sender_id, recipient_id)

  defp dm_thread_id(a, b) do
    [x, y] = Enum.sort([a, b])
    "dm:#{x}:#{y}"
  end
end