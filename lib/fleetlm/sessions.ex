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
  alias Fleetlm.Sessions.Cache
  alias Fleetlm.Sessions.ChatSession
  alias Fleetlm.Sessions.ChatMessage
  alias Fleetlm.Sessions.SessionServer
  alias Fleetlm.Sessions.InboxSupervisor
  alias Fleetlm.Sessions.InboxServer
  alias Fleetlm.Agents.Dispatcher
  alias Fleetlm.Observability
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
    kind = Map.get(attrs, :kind) || Map.get(attrs, "kind") || "text"

    Observability.measure_session_append(session_id, %{kind: kind}, fn ->
      # Use optimized single-query approach if available, fallback to multi-query
      case append_message_optimized(session_id, attrs) do
        {:ok, _message} = ok ->
          {ok, %{strategy: :optimized}}

        {:fallback, reason} ->
          result = append_message_fallback(session_id, attrs)
          {result, %{strategy: :fallback, fallback_reason: inspect(reason)}}

        {:error, _reason} = error ->
          {error, %{strategy: :optimized}}
      end
    end)
  end

  # Optimized single-SQL-statement approach
  defp append_message_optimized(session_id, attrs) do
    try do
      # Prepare message attributes
      message_id = Ulid.generate()
      message_attrs = prepare_message_attrs(attrs, session_id, message_id)

      # Validate attributes using changeset
      changeset = ChatMessage.changeset(%ChatMessage{}, message_attrs)

      if changeset.valid? do
        # Execute atomic SQL operation
        case execute_atomic_message_insert(message_attrs) do
          {:ok, result} ->
            message = struct(ChatMessage, result)
            session = get_session!(session_id)
            post_message_processing(message, session)
            {:ok, message}

          {:error, reason} ->
            {:error, reason}
        end
      else
        {:error, changeset}
      end
    rescue
      error ->
        {:fallback, error}
    end
  end

  # Fallback to original multi-query approach
  defp append_message_fallback(session_id, attrs) do
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

               message_for_runtime =
                 message
                 |> Map.from_struct()
                 |> Map.put(:session, runtime_session)

               {message, message_for_runtime, runtime_session, dispatch_payload}

             {:error, changeset} ->
               Repo.rollback(changeset)
           end
         end) do
      {:ok, {message, message_for_runtime, runtime_session, dispatch_payload}} ->
        SessionServer.append_message(message_for_runtime)
        Dispatcher.maybe_dispatch(runtime_session, dispatch_payload)
        {:ok, message}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Mark messages in a session as read for the given participant.
  """
  @spec mark_read(String.t(), String.t(), keyword()) ::
          {:ok, ChatSession.t()} | {:error, term()}
  def mark_read(session_id, participant_id, opts \\ [])
      when is_binary(session_id) and is_binary(participant_id) do
    message_id = Keyword.get(opts, :message_id)

    with {:ok, session} <- do_mark_read(session_id, participant_id, message_id) do
      _ = refresh_inbox(participant_id)
      {:ok, session}
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

  @doc """
  List recent sessions for a participant with unread counts, using cache-first approach.
  Returns tuples of {session, unread_count}.
  """
  @spec list_sessions_with_unread_counts(String.t(), keyword()) :: [
          {ChatSession.t(), non_neg_integer()}
        ]
  def list_sessions_with_unread_counts(participant_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)

    sessions =
      ChatSession
      |> where([s], s.initiator_id == ^participant_id or s.peer_id == ^participant_id)
      |> order_by([s], desc: s.inserted_at)
      |> limit(^limit)
      |> Repo.all()

    # Optimize: Batch cache lookups and fallback to single DB query
    sessions_with_roles =
      Enum.map(sessions, fn session ->
        {session, participant_role(session, participant_id)}
      end)

    # Try to get all unread counts from cache first
    {cached_counts, sessions_requiring_db} =
      Enum.reduce(sessions_with_roles, {%{}, []}, fn {session, role}, {cache_acc, pending} ->
        case role do
          nil ->
            {Map.put(cache_acc, session.id, 0), pending}

          role ->
            last_read_at = session_last_read_at(session, role)

            case SessionServer.cached_unread_count(session.id, participant_id, last_read_at) do
              nil -> {cache_acc, [{session, role} | pending]}
              cached -> {Map.put(cache_acc, session.id, cached), pending}
            end
        end
      end)

    # Single optimized DB query for all cache misses
    db_counts = fetch_unread_counts_from_db_optimized(sessions_requiring_db, participant_id)

    unread_counts = Map.merge(db_counts, cached_counts)

    Enum.map(sessions, fn session ->
      {session, Map.get(unread_counts, session.id, 0)}
    end)
  end

  @doc """
  Get inbox snapshot with read-through caching.
  Returns cached version if available and fresh, otherwise builds new one.
  """
  @spec get_inbox_snapshot(String.t(), keyword()) :: [map()]
  def get_inbox_snapshot(participant_id, opts \\ []) do
    cache_ttl_ms = Keyword.get(opts, :cache_ttl_ms, :timer.minutes(5))
    limit = Keyword.get(opts, :limit, @default_limit)

    case Cache.fetch_inbox_snapshot(participant_id) do
      {:ok, snapshot} ->
        snapshot

      _ ->
        # Cache miss - build new snapshot
        snapshot = build_inbox_snapshot(participant_id, limit: limit)
        Cache.put_inbox_snapshot(participant_id, snapshot, cache_ttl_ms)
        snapshot
    end
  end

  defp build_inbox_snapshot(participant_id, opts) do
    limit = Keyword.get(opts, :limit, @default_limit)

    sessions_with_counts = list_sessions_with_unread_counts(participant_id, limit: limit)

    Enum.map(sessions_with_counts, fn {session, unread_count} ->
      # Try to get fresher metadata from cache if session is active
      {last_message_id, last_message_at} =
        case Fleetlm.Sessions.SessionServer.cached_inbox_metadata(session.id) do
          %{last_message_id: id, last_message_at: at} when not is_nil(id) ->
            {id, encode_datetime(at)}

          _ ->
            # Fall back to database values
            {session.last_message_id, encode_datetime(session.last_message_at)}
        end

      %{
        "session_id" => session.id,
        "kind" => session.kind,
        "status" => session.status,
        "last_message_id" => last_message_id,
        "last_message_at" => last_message_at,
        "agent_id" => session.agent_id,
        "initiator_id" => session.initiator_id,
        "peer_id" => session.peer_id,
        "initiator_last_read_id" => session.initiator_last_read_id,
        "initiator_last_read_at" => encode_datetime(session.initiator_last_read_at),
        "peer_last_read_id" => session.peer_last_read_id,
        "peer_last_read_at" => encode_datetime(session.peer_last_read_at),
        "unread_count" => unread_count
      }
    end)
  end

  defp encode_datetime(nil), do: nil
  defp encode_datetime(%NaiveDateTime{} = naive), do: NaiveDateTime.to_iso8601(naive)
  defp encode_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  @doc """
  Count unread messages for the given participant in the session.
  """
  @spec unread_count(ChatSession.t(), String.t()) :: non_neg_integer()
  def unread_count(%ChatSession{} = session, participant_id) when is_binary(participant_id) do
    case participant_role(session, participant_id) do
      :initiator -> do_unread_count(session, participant_id, :initiator_last_read_at)
      :peer -> do_unread_count(session, participant_id, :peer_last_read_at)
      nil -> 0
    end
  end


  # Optimized version that uses a single query for all sessions
  defp fetch_unread_counts_from_db_optimized([], _participant_id), do: %{}

  defp fetch_unread_counts_from_db_optimized(sessions_with_role, participant_id) do
    case sessions_with_role do
      [] -> %{}
      sessions_with_role ->
        # Extract all session IDs for a single query
        session_ids = Enum.map(sessions_with_role, fn {session, _role} -> session.id end)

        # Single query that handles both initiator and peer cases
        ChatMessage
        |> join(:inner, [m], s in ChatSession, on: s.id == m.session_id)
        |> where([_m, s], s.id in ^session_ids)
        |> where([m, s],
          (s.initiator_id == ^participant_id and m.sender_id != ^participant_id and
           (is_nil(s.initiator_last_read_at) or m.inserted_at > s.initiator_last_read_at)) or
          (s.peer_id == ^participant_id and m.sender_id != ^participant_id and
           (is_nil(s.peer_last_read_at) or m.inserted_at > s.peer_last_read_at))
        )
        |> group_by([_m, s], s.id)
        |> select([m, s], {s.id, count(m.id)})
        |> Repo.all()
        |> Map.new()
    end
  end


  defp session_last_read_at(%ChatSession{} = session, :initiator),
    do: session.initiator_last_read_at

  defp session_last_read_at(%ChatSession{} = session, :peer), do: session.peer_last_read_at

  # Helper functions for optimized append_message

  defp prepare_message_attrs(attrs, session_id, message_id) do
    attrs
    |> Map.take([:sender_id, :kind, :content, :metadata])
    |> Map.put(:session_id, session_id)
    |> Map.put_new(:content, %{})
    |> Map.put_new(:metadata, %{})
    |> Map.put(:shard_key, shard_key_for(session_id))
    |> Map.put(:id, message_id)
  end

  defp execute_atomic_message_insert(message_attrs) do
    # SQL CTE that inserts message and updates session in single atomic operation
    sql = """
    WITH inserted_message AS (
      INSERT INTO chat_messages (id, session_id, sender_id, kind, content, metadata, shard_key, inserted_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7, NOW())
      RETURNING *
    ),
    updated_session AS (
      UPDATE chat_sessions
      SET last_message_id = $1,
          last_message_at = (SELECT inserted_at FROM inserted_message),
          updated_at = NOW()
      WHERE id = $2
      RETURNING agent_id
    )
    SELECT
      im.*,
      us.agent_id as session_agent_id
    FROM inserted_message im, updated_session us
    """

    params = [
      message_attrs[:id],
      message_attrs[:session_id],
      message_attrs[:sender_id],
      message_attrs[:kind],
      message_attrs[:content],
      message_attrs[:metadata],
      message_attrs[:shard_key]
    ]

    case Ecto.Adapters.SQL.query(Repo, sql, params) do
      {:ok, %{rows: [row], columns: columns}} ->
        # Convert row data back to map
        result =
          columns
          |> Enum.zip(row)
          |> Map.new()
          |> convert_db_result_to_message()

        {:ok, result}

      {:ok, %{rows: []}} ->
        {:error, :session_not_found}

      {:error, error} ->
        {:error, error}
    end
  end

  defp convert_db_result_to_message(db_result) do
    # Convert database result to message-like map
    %{
      id: db_result["id"],
      session_id: db_result["session_id"],
      sender_id: db_result["sender_id"],
      kind: db_result["kind"],
      content: db_result["content"],
      metadata: db_result["metadata"],
      shard_key: db_result["shard_key"],
      inserted_at: db_result["inserted_at"],
      updated_at: db_result["updated_at"],
      session_agent_id: db_result["session_agent_id"]
    }
  end

  defp post_message_processing(message, session) do
    runtime_session =
      session
      |> Map.put(:last_message_id, message.id)
      |> Map.put(:last_message_at, to_datetime(message.inserted_at))

    # Build dispatch payload
    dispatch_payload = %{
      id: message.id,
      session_id: message.session_id,
      sender_id: message.sender_id,
      kind: message.kind,
      content: message.content,
      metadata: message.metadata,
      inserted_at: message.inserted_at
    }

    # Build message for runtime
    message_for_runtime = Map.put(message, :session, runtime_session)

    # Execute side effects
    SessionServer.append_message(message_for_runtime)
    Dispatcher.maybe_dispatch(runtime_session, dispatch_payload)

    :ok
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

  defp do_mark_read(session_id, participant_id, message_id) do
    Repo.transaction(fn ->
      session = Repo.get!(ChatSession, session_id)

      case participant_role(session, participant_id) do
        nil ->
          Repo.rollback({:error, :invalid_participant})

        role ->
          case resolve_message(session, message_id) do
            {:ok, {resolved_id, resolved_at}} ->
              read_attrs = build_read_attrs(role, resolved_id, resolved_at)

              session
              |> ChatSession.changeset(read_attrs)
              |> Repo.update()
              |> case do
                {:ok, updated_session} -> updated_session
                {:error, changeset} -> Repo.rollback(changeset)
              end

            {:error, reason} ->
              Repo.rollback({:error, reason})
          end
      end
    end)
    |> case do
      {:ok, session} -> {:ok, session}
      {:error, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp participant_role(%ChatSession{} = session, participant_id) do
    cond do
      session.initiator_id == participant_id -> :initiator
      session.peer_id == participant_id -> :peer
      true -> nil
    end
  end

  defp resolve_message(session, nil) do
    if session.last_message_id do
      Repo.get(ChatMessage, session.last_message_id)
      |> case do
        %ChatMessage{} = message -> {:ok, {message.id, to_datetime(message.inserted_at)}}
        nil -> {:error, :message_not_found}
      end
    else
      {:ok, {nil, DateTime.utc_now()}}
    end
  end

  defp resolve_message(%ChatSession{} = session, message_id) when is_binary(message_id) do
    session_id = session.id

    case Repo.get(ChatMessage, message_id) do
      %ChatMessage{session_id: ^session_id} = message ->
        {:ok, {message.id, to_datetime(message.inserted_at)}}

      _ ->
        {:error, :message_not_found}
    end
  end

  defp build_read_attrs(:initiator, message_id, read_at) do
    %{
      initiator_last_read_id: message_id,
      initiator_last_read_at: read_at
    }
  end

  defp build_read_attrs(:peer, message_id, read_at) do
    %{
      peer_last_read_id: message_id,
      peer_last_read_at: read_at
    }
  end

  defp do_unread_count(%ChatSession{} = session, participant_id, read_field) do
    read_at = Map.get(session, read_field)
    do_unread_count_from_db(session, participant_id, read_at)
  end

  defp do_unread_count_from_db(%ChatSession{} = session, participant_id, read_at) do
    ChatMessage
    |> where([m], m.session_id == ^session.id)
    |> where([m], m.sender_id != ^participant_id)
    |> maybe_after_time(read_at)
    |> select([m], count(m.id))
    |> Repo.one()
  end

  defp maybe_after_time(query, nil), do: query

  defp maybe_after_time(query, %DateTime{} = dt) do
    naive = DateTime.to_naive(dt)
    from m in query, where: m.inserted_at > ^naive
  end

  defp maybe_after_time(query, %NaiveDateTime{} = naive),
    do: from(m in query, where: m.inserted_at > ^naive)

  defp refresh_inbox(participant_id) do
    case InboxSupervisor.ensure_started(participant_id) do
      {:ok, _pid} -> InboxServer.flush(participant_id)
      {:error, _} -> :ok
    end
  end
end
