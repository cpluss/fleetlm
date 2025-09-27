defmodule Fleetlm.Conversation.Persistence do
  @moduledoc """
  Durable persistence helpers for the hot-path slot log.

  The persistence worker feeds `Fleetlm.Runtime.Storage.Entry` structs here so
  we can materialise them in Postgres and keep the `chat_sessions` table in
  sync. The implementation is idempotent and safe to rerun for the same entry,
  which lets crash recovery simply replay the disk log from the beginning.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Fleetlm.Agent.Dispatcher
  alias Fleetlm.Conversation.{ChatMessage, ChatSession}
  alias Fleetlm.Runtime.Storage.Entry
  alias Fleetlm.Repo

  @spec persist_entry(Entry.t()) :: :ok | :already_persisted | {:error, term()}
  def persist_entry(%Entry{} = entry) do
    result =
      Repo.transaction(fn ->
        with status when status in [:new, :duplicate] <- insert_message(entry),
             :ok <- update_session(entry) do
          status
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, :new} ->
        maybe_dispatch(entry)
        :ok

      {:ok, :duplicate} ->
        :already_persisted

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp insert_message(%Entry{} = entry) do
    message = entry.payload

    case Repo.get(ChatMessage, message.id) do
      %ChatMessage{} ->
        :duplicate

      nil ->
        attrs = %{
          id: message.id,
          session_id: message.session_id,
          sender_id: message.sender_id,
          kind: message.kind,
          content: message.content,
          metadata: message.metadata,
          shard_key: shard_key_for(message.session_id)
        }

        changeset =
          %ChatMessage{}
          |> ChatMessage.changeset(attrs)
          |> Changeset.put_change(:inserted_at, entry.inserted_at)

        case Repo.insert(changeset) do
          {:ok, _} ->
            :new

          {:error, changeset} ->
            if Repo.get(ChatMessage, message.id) do
              :duplicate
            else
              {:error, {:insert_failed, changeset}}
            end
        end
    end
  end

  defp update_session(%Entry{} = entry) do
    update = [
      last_message_id: entry.message_id,
      last_message_at: entry.inserted_at,
      updated_at: entry.inserted_at
    ]

    case Repo.update_all(from(s in ChatSession, where: s.id == ^entry.session_id), set: update) do
      {c, _} when c >= 1 -> :ok
      _ -> {:error, :session_not_found}
    end
  end

  defp maybe_dispatch(%Entry{} = entry) do
    message = entry.payload
    session = message_session_snapshot(message)
    payload = build_dispatch_payload(message)
    Dispatcher.maybe_dispatch(session, payload)
  end

  defp message_session_snapshot(message) do
    case Map.get(message, :session) do
      nil ->
        %{
          id: message.session_id,
          agent_id: Map.get(message, :agent_id),
          initiator_id: Map.get(message, :initiator_id),
          peer_id: Map.get(message, :peer_id),
          kind: Map.get(message, :kind)
        }
        |> Map.put(:last_message_id, message.id)
        |> Map.put(:last_message_at, message.inserted_at)

      session ->
        session
        |> Map.put(:last_message_id, message.id)
        |> Map.put(:last_message_at, message.inserted_at)
    end
  end

  defp build_dispatch_payload(message) do
    %{
      id: message.id,
      session_id: message.session_id,
      sender_id: message.sender_id,
      kind: message.kind,
      content: message.content,
      metadata: message.metadata,
      inserted_at: message.inserted_at
    }
  end

  defp shard_key_for(session_id), do: :erlang.phash2(session_id, 1024)
end
