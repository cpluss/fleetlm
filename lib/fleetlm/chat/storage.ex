defmodule Fleetlm.Chat.Storage do
  @moduledoc """
  Storage layer for all chat data. All database interactions flow through this module
  and are wrapped in order to protect against database failures.
  """

  import Ecto.Query, warn: false

  alias Fleetlm.Repo
  alias Fleetlm.Chat.{DmMessage, BroadcastMessage, DmKey}

  @default_history_limit 50

  @spec persist_dm_message(String.t(), String.t(), String.t(), String.t() | nil, map()) ::
          {:ok, DmMessage.t()} | {:error, term()}
  def persist_dm_message(dm_key, sender_id, recipient_id, text, metadata) do
    attrs = %{
      sender_id: sender_id,
      recipient_id: recipient_id,
      dm_key: dm_key,
      text: text,
      metadata: metadata || %{}
    }

    execute(fn ->
      %DmMessage{}
      |> DmMessage.changeset(attrs)
      |> Repo.insert()
    end)
  end

  @spec list_dm_tail(String.t(), keyword()) :: [DmMessage.t()]
  def list_dm_tail(dm_key, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_history_limit)

    DmMessage
    |> where([m], m.dm_key == ^dm_key)
    |> order_by([m], desc: m.created_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @spec list_dm_threads(String.t(), keyword()) :: [map()]
  def list_dm_threads(participant_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

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
      last_message_text,
      last_sender_id
    FROM latest_by_dm_key
    ORDER BY last_message_at DESC
    LIMIT $2
    """

    execute(fn -> Repo.query(query, [participant_id, limit]) end)
    |> case do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [
                            dm_key,
                            other_participant_id,
                            last_message_at,
                            last_message_text,
                            last_sender_id
                          ] ->
          %{
            dm_key: dm_key,
            other_participant_id: other_participant_id,
            last_message_at: last_message_at,
            last_message_text: last_message_text,
            last_sender_id: last_sender_id
          }
        end)

      _ ->
        []
    end
  end

  @spec persist_broadcast_message(String.t(), String.t() | nil, map()) ::
          {:ok, BroadcastMessage.t()} | {:error, term()}
  def persist_broadcast_message(sender_id, text, metadata) do
    attrs = %{
      sender_id: sender_id,
      text: text,
      metadata: metadata || %{}
    }

    execute(fn ->
      %BroadcastMessage{}
      |> BroadcastMessage.changeset(attrs)
      |> Repo.insert()
    end)
  end

  @spec list_broadcast_messages(keyword()) :: [BroadcastMessage.t()]
  def list_broadcast_messages(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    BroadcastMessage
    |> order_by([m], desc: m.created_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @spec participants_for_dm(String.t()) :: {String.t(), String.t()}
  def participants_for_dm(dm_key) do
    dm_key
    |> DmKey.parse!()
    |> then(&{&1.first, &1.second})
  end

  defp execute(fun) when is_function(fun, 0), do: fun.()
end
