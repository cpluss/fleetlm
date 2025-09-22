defmodule Fleetlm.Chat do
  import Ecto.Query, warn: false

  alias Fleetlm.Repo
  alias Fleetlm.Chat.{DmMessage, BroadcastMessage}

  @default_page_size 40
  @max_page_size 200

  ## DM Operations

  def generate_dm_key(participant_a, participant_b) do
    DmMessage.generate_dm_key(participant_a, participant_b)
  end

  def create_dm(sender_id, recipient_id, initial_message \\ nil) do
    dm_key = generate_dm_key(sender_id, recipient_id)

    # Send initial message if provided
    result = if initial_message && String.trim(initial_message) != "" do
      send_dm_message(sender_id, recipient_id, initial_message)
    else
      {:ok, nil}
    end

    case result do
      {:ok, message} ->
        # Only broadcast DM creation if there's no initial message
        # (send_dm_message already handles broadcasting when there is a message)
        if message == nil do
          Fleetlm.Chat.Events.broadcast_dm_created(dm_key, sender_id, recipient_id, nil)
        end
        {:ok, %{dm_key: dm_key, initial_message: message}}

      error ->
        error
    end
  end

  def send_dm_message(sender_id, recipient_id, text, metadata \\ %{}) do
    attrs = %{
      sender_id: sender_id,
      recipient_id: recipient_id,
      text: text,
      metadata: metadata
    }

    case %DmMessage{}
         |> DmMessage.changeset(attrs)
         |> Repo.insert() do
      {:ok, message} = result ->
        # Emit domain event for real-time notifications
        Fleetlm.Chat.Events.broadcast_dm_message(message)
        result

      error ->
        error
    end
  end

  def get_dm_conversation(user_a_id, user_b_id, opts \\ []) do
    limit = limit_from_opts(opts)
    dm_key = DmMessage.generate_dm_key(user_a_id, user_b_id)

    DmMessage
    |> where([m], m.dm_key == ^dm_key)
    |> order_by([m], desc: m.created_at)
    |> maybe_before(opts[:before])
    |> maybe_after(opts[:after])
    |> limit(^limit)
    |> Repo.all()
  end

  def get_dm_conversation_by_key(dm_key, opts \\ []) do
    limit = limit_from_opts(opts)

    DmMessage
    |> where([m], m.dm_key == ^dm_key)
    |> order_by([m], desc: m.created_at)
    |> maybe_before(opts[:before])
    |> maybe_after(opts[:after])
    |> limit(^limit)
    |> Repo.all()
  end

  def get_dm_threads_for_user(user_id, opts \\ []) do
    limit = limit_from_opts(opts)

    # Much simpler query using dm_key
    query = """
    WITH latest_by_dm_key AS (
      SELECT DISTINCT
        dm_key,
        FIRST_VALUE(created_at) OVER (PARTITION BY dm_key ORDER BY created_at DESC) as last_message_at,
        FIRST_VALUE(text) OVER (PARTITION BY dm_key ORDER BY created_at DESC) as last_message_text,
        FIRST_VALUE(sender_id) OVER (PARTITION BY dm_key ORDER BY created_at DESC) as last_sender_id,
        FIRST_VALUE(recipient_id) OVER (PARTITION BY dm_key ORDER BY created_at DESC) as last_recipient_id
      FROM dm_messages
      WHERE sender_id = $1 OR recipient_id = $1
    )
    SELECT
      dm_key,
      CASE WHEN last_sender_id = $1 THEN last_recipient_id ELSE last_sender_id END as other_participant_id,
      last_message_at,
      last_message_text
    FROM latest_by_dm_key
    ORDER BY last_message_at DESC
    LIMIT $2
    """

    case Repo.query(query, [user_id, limit]) do
      {:ok, result} ->
        Enum.map(result.rows, fn [dm_key, other_participant_id, last_message_at, last_message_text] ->
          %{
            dm_key: dm_key,
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

    case %BroadcastMessage{}
         |> BroadcastMessage.changeset(attrs)
         |> Repo.insert() do
      {:ok, message} = result ->
        # Emit domain event for real-time notifications
        Fleetlm.Chat.Events.broadcast_broadcast_message(message)
        result

      error ->
        error
    end
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