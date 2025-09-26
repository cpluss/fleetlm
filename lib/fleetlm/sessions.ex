defmodule Fleetlm.Sessions do
  @moduledoc """
  Context boundary for the new session-based chat runtime.

  This module owns the persisted representation of a two-party chat session,
  provides helper functions to create sessions, append messages, and list
  session history, and coordinates with the runtime layer (`SessionServer`)
  to keep cached tails/inbox projections in sync. All public APIs here return
  plain Ecto structs and push side effects (PubSub fan-out, cache updates) into
  the session runtime.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Fleetlm.Repo
  alias Fleetlm.Participants
  alias Fleetlm.Sessions.ChatSession
  alias Fleetlm.Sessions.ChatMessage
  alias Fleetlm.Sessions.SessionServer
  alias Fleetlm.Agents.Dispatcher
  alias Ulid

  @default_limit 50

  @doc """
  Start a new chat session between two participants.
  """
  @spec start_session(map()) :: {:ok, ChatSession.t()} | {:error, Ecto.Changeset.t()}
  def start_session(attrs) when is_map(attrs) do
    initiator_id = fetch_id!(attrs, :initiator_id)
    peer_id = fetch_id!(attrs, :peer_id)

    if initiator_id == peer_id do
      {:error,
       %ChatSession{}
       |> Changeset.change(%{initiator_id: initiator_id, peer_id: peer_id})
       |> Changeset.add_error(:peer_id, "must be different from initiator")}
    else
      Repo.transaction(fn ->
        initiator = Participants.get_participant!(initiator_id)
        peer = Participants.get_participant!(peer_id)

        {kind, agent_id} = infer_kind_and_agent(initiator, peer)

        session_attrs =
          attrs
          |> Map.take([:initiator_id, :peer_id, :kind, :metadata])
          |> Map.put_new(:kind, kind)
          |> Map.put(:agent_id, agent_id)
          |> Map.put_new(:id, Ulid.generate())

        %ChatSession{}
        |> ChatSession.changeset(session_attrs)
        |> Repo.insert()
        |> case do
          {:ok, session} -> session
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)
      |> unwrap_transaction()
    end
  end

  @doc """
  Fetch a session by id.
  """
  @spec get_session!(String.t()) :: ChatSession.t()
  def get_session!(id) when is_binary(id) do
    Repo.get!(ChatSession, id)
  end

  @doc """
  Append a message to a session.
  """
  @spec append_message(String.t(), map()) :: {:ok, ChatMessage.t()} | {:error, Ecto.Changeset.t()}
  def append_message(session_id, attrs) when is_binary(session_id) and is_map(attrs) do
    case Repo.transaction(fn ->
           session = Repo.get!(ChatSession, session_id)

           message_attrs =
             attrs
             |> Map.take([:sender_id, :kind, :content, :metadata])
             |> Map.put(:session_id, session.id)
             |> Map.put_new(:content, %{})
             |> Map.put_new(:metadata, %{})
             |> Map.put(:shard_key, shard_key_for(session.id))
             |> Map.put_new(:id, Ulid.generate())

           %ChatMessage{}
           |> ChatMessage.changeset(message_attrs)
           |> Repo.insert()
           |> case do
             {:ok, message} ->
               {:ok, _} =
                 session
                 |> ChatSession.changeset(%{
                   last_message_id: message.id,
                   last_message_at: message.inserted_at
                 })
                 |> Repo.update()

               runtime_session =
                 session
                 |> Map.put(:last_message_id, message.id)
                 |> Map.put(:last_message_at, to_datetime(message.inserted_at))

               message_for_runtime =
                 message
                 |> Map.from_struct()
                 |> Map.put(:session, runtime_session)

               SessionServer.append_message(message_for_runtime)

               dispatch_payload =
                 message
                 |> Map.from_struct()
                 |> Map.take([
                   :id,
                   :session_id,
                   :sender_id,
                   :kind,
                   :content,
                   :metadata,
                   :inserted_at
                 ])

               {message, runtime_session, dispatch_payload}

             {:error, changeset} ->
               Repo.rollback(changeset)
           end
         end) do
      {:ok, {message, runtime_session, dispatch_payload}} ->
        Dispatcher.maybe_dispatch(runtime_session, dispatch_payload)
        {:ok, message}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  List messages for a session ordered by ULID ascending.
  """
  @spec list_messages(String.t(), keyword()) :: [ChatMessage.t()]
  def list_messages(session_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)
    after_id = Keyword.get(opts, :after_id)

    ChatMessage
    |> where([m], m.session_id == ^session_id)
    |> maybe_after_id(after_id)
    |> order_by([m], asc: m.id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  List recent sessions for a participant.
  """
  @spec list_sessions_for_participant(String.t(), keyword()) :: [ChatSession.t()]
  def list_sessions_for_participant(participant_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)

    ChatSession
    |> where(
      [s],
      s.initiator_id == ^participant_id or s.peer_id == ^participant_id
    )
    |> order_by([s], desc: s.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  defp fetch_id!(attrs, key) do
    case Map.fetch(attrs, key) || Map.fetch(attrs, Atom.to_string(key)) do
      {:ok, value} when is_binary(value) -> value
      {:ok, value} -> to_string(value)
      :error -> raise ArgumentError, "#{key} is required"
    end
  end

  defp infer_kind_and_agent(%{kind: "agent"} = agent, _other), do: {"agent_dm", agent.id}
  defp infer_kind_and_agent(_other, %{kind: "agent"} = agent), do: {"agent_dm", agent.id}
  defp infer_kind_and_agent(_a, _b), do: {"human_dm", nil}

  defp shard_key_for(session_id), do: :erlang.phash2(session_id, 1024)

  defp to_datetime(%NaiveDateTime{} = naive), do: DateTime.from_naive!(naive, "Etc/UTC")
  defp to_datetime(%DateTime{} = dt), do: dt

  defp maybe_after_id(query, nil), do: query

  defp maybe_after_id(query, after_id) when is_binary(after_id) do
    from m in query, where: m.id > ^after_id
  end

  defp unwrap_transaction({:ok, result}), do: {:ok, result}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}
end
