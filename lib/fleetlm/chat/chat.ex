defmodule Fleetlm.Chat do
  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias Fleetlm.Repo
  alias Fleetlm.Chat.ThreadServer
  alias Fleetlm.Chat.Threads.{Message, Participant, Thread}

  @default_page_size 50
  @max_page_size 200
  @default_shard_modulus 1024
  @message_keys [:thread_id, :sender_id, :role, :kind, :text, :metadata]

  # Build DM key for two participants (unordered), "a:b"
  def dm_key(a, b) do
    [x, y] = Enum.sort([a, b])
    "#{x}:#{y}"
  end

  def ensure_dm!(a_id, b_id, opts \\ []) do
    roles = Keyword.get(opts, :roles)
    {a_role, b_role} = normalize_roles(roles)

    key = dm_key(a_id, b_id)

    Repo.transaction(fn ->
      case Repo.get_by(Thread, dm_key: key) do
        %Thread{} = thread ->
          ensure_thread_participant!(thread, a_id, a_role)
          ensure_thread_participant!(thread, b_id, b_role)
          thread

        nil ->
          thread =
            %Thread{}
            |> Thread.changeset(%{dm_key: key, kind: "dm"})
            |> Repo.insert!()

          ensure_thread_participant!(thread, a_id, a_role)
          ensure_thread_participant!(thread, b_id, b_role)

          thread
      end
    end)
    |> case do
      {:ok, thread} -> thread
      {:error, reason} -> raise(reason)
    end
  end

  def get_or_create_dm!(a_id, b_id), do: ensure_dm!(a_id, b_id)

  def get_thread!(id, opts \\ []) do
    Thread
    |> maybe_preload(opts[:preload])
    |> Repo.get!(id)
  end

  def list_thread_messages(thread_id, opts \\ []) do
    limit = limit_from_opts(opts)

    Message
    |> where([m], m.thread_id == ^thread_id)
    |> order_by([m], desc: m.created_at, desc: m.id)
    |> maybe_before(opts[:before])
    |> maybe_after(opts[:after])
    |> limit(^limit)
    |> Repo.all()
  end

  def list_threads_for_participant(participant_id, opts \\ []) do
    limit = limit_from_opts(opts)

    Participant
    |> where([p], p.participant_id == ^participant_id)
    |> join(:inner, [p], t in assoc(p, :thread))
    |> order_by([p, _t], desc: p.last_message_at, desc: p.joined_at)
    |> maybe_before_participant(opts[:before])
    |> preload([p, t], thread: t)
    |> limit(^limit)
    |> Repo.all()
  end

  def send_message(attrs, opts \\ []) when is_map(attrs) do
    attrs = normalize_message_attrs(attrs)

    thread_id = fetch_required!(attrs, :thread_id)
    sender_id = fetch_required!(attrs, :sender_id)
    role = attrs |> Map.get(:role, "user") |> to_string()

    message_attrs =
      attrs
      |> Map.put(:thread_id, thread_id)
      |> Map.put(:sender_id, sender_id)
      |> Map.put(:role, role)
      |> Map.put(:shard_key, shard_for(thread_id, opts))

    Multi.new()
    |> Multi.run(:thread, fn _, _ -> fetch_thread(thread_id) end)
    |> Multi.run(:sender, fn _, %{thread: thread} ->
      ensure_thread_participant(thread, sender_id, role)
    end)
    |> Multi.insert(:message, Message.changeset(%Message{}, message_attrs))
    |> Multi.run(:touch_sender, fn _, %{message: message} ->
      touch_sender(thread_id, sender_id, message)
    end)
    |> Multi.run(:touch_recipients, fn _, %{message: message} ->
      touch_recipients(thread_id, sender_id, message)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{message: message}} -> {:ok, message}
      {:error, step, reason, _changes} -> {:error, step, reason}
    end
  end

  def ack_read(thread_id, participant_id, cursor \\ DateTime.utc_now()) do
    cursor = normalize_datetime!(cursor)

    Repo.transaction(fn ->
      case Repo.get_by(Participant, thread_id: thread_id, participant_id: participant_id) do
        nil ->
          {:error, :not_found}

        %Participant{} = participant ->
          maybe_update_read_cursor(participant, cursor)
      end
    end)
    |> case do
      {:ok, {:ok, participant}} -> {:ok, participant}
      {:ok, {:noop, participant}} -> {:ok, participant}
      {:ok, {:error, _} = error} -> error
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_roles({a_role, b_role}), do: {to_string(a_role), to_string(b_role)}
  defp normalize_roles([a_role, b_role]), do: {to_string(a_role), to_string(b_role)}
  defp normalize_roles(role) when is_binary(role), do: {role, role}
  defp normalize_roles(nil), do: {"user", "user"}
  defp normalize_roles(_), do: raise(ArgumentError, "expected roles to be {a, b} or [a, b]")

  defp fetch_thread(id) do
    case Repo.get(Thread, id) do
      %Thread{} = thread -> {:ok, thread}
      nil -> {:error, :not_found}
    end
  end

  defp ensure_thread_participant(thread, participant_id, role) do
    {:ok, ensure_thread_participant!(thread, participant_id, role)}
  end

  defp ensure_thread_participant!(%Thread{} = thread, participant_id, role) do
    changes = %{
      thread_id: thread.id,
      participant_id: participant_id,
      role: role
    }

    Repo.insert!(
      Participant.changeset(%Participant{}, changes),
      on_conflict: [set: [role: role]],
      conflict_target: [:thread_id, :participant_id],
      returning: true
    )
  end

  defp touch_sender(thread_id, sender_id, message) do
    update_fields = [
      last_message_at: message.created_at,
      last_message_preview: message.text,
      read_cursor_at: message.created_at
    ]

    {count, _} =
      Participant
      |> where([p], p.thread_id == ^thread_id and p.participant_id == ^sender_id)
      |> Repo.update_all(set: update_fields)

    if count == 0, do: {:error, :participant_missing}, else: {:ok, count}
  end

  defp touch_recipients(thread_id, sender_id, message) do
    update_fields = [
      last_message_at: message.created_at,
      last_message_preview: message.text
    ]

    Participant
    |> where([p], p.thread_id == ^thread_id and p.participant_id != ^sender_id)
    |> Repo.update_all(set: update_fields)

    {:ok, :updated}
  end

  defp maybe_update_read_cursor(%Participant{} = participant, %DateTime{} = cursor) do
    cursor = DateTime.truncate(cursor, :microsecond)

    case participant.read_cursor_at do
      nil ->
        participant
        |> Participant.changeset(%{read_cursor_at: cursor})
        |> Repo.update()

      %DateTime{} = existing ->
        if DateTime.compare(existing, cursor) == :lt do
          participant
          |> Participant.changeset(%{read_cursor_at: cursor})
          |> Repo.update()
        else
          {:noop, participant}
        end
    end
  end

  defp maybe_preload(queryable, nil), do: queryable
  defp maybe_preload(queryable, preload), do: preload(queryable, ^List.wrap(preload))

  defp maybe_before(query, nil), do: query

  defp maybe_before(query, cursor) do
    {created_at, id} = normalize_message_cursor(cursor)

    case id do
      nil ->
        where(query, [m], m.created_at < ^created_at)

      _ ->
        where(
          query,
          [m],
          m.created_at < ^created_at or (m.created_at == ^created_at and m.id < ^id)
        )
    end
  end

  defp maybe_after(query, nil), do: query

  defp maybe_after(query, cursor) do
    {created_at, id} = normalize_message_cursor(cursor)

    case id do
      nil ->
        where(query, [m], m.created_at > ^created_at)

      _ ->
        where(
          query,
          [m],
          m.created_at > ^created_at or (m.created_at == ^created_at and m.id > ^id)
        )
    end
  end

  defp maybe_before_participant(query, nil), do: query

  defp maybe_before_participant(query, cursor) do
    timestamp = normalize_datetime!(cursor)

    where(
      query,
      [p, _t],
      fragment("coalesce(?, ?) < ?", p.last_message_at, p.joined_at, ^timestamp)
    )
  end

  defp normalize_message_attrs(attrs) do
    Enum.reduce(attrs, %{}, fn
      {key, value}, acc when is_atom(key) and key in @message_keys ->
        Map.put(acc, key, value)

      {key, value}, acc when is_binary(key) ->
        case key do
          "thread_id" -> Map.put(acc, :thread_id, value)
          "sender_id" -> Map.put(acc, :sender_id, value)
          "role" -> Map.put(acc, :role, value)
          "kind" -> Map.put(acc, :kind, value)
          "text" -> Map.put(acc, :text, value)
          "metadata" -> Map.put(acc, :metadata, value)
          _ -> acc
        end

      _, acc ->
        acc
    end)
  end

  defp fetch_required!(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> value
      :error -> raise KeyError, message: "required key #{inspect(key)} not found"
    end
  end

  defp shard_for(thread_id, opts) do
    modulus =
      opts
      |> Keyword.get(:shard_modulus, @default_shard_modulus)
      |> normalize_modulus()

    :erlang.phash2(thread_id, modulus)
  end

  defp normalize_modulus(modulus) when is_integer(modulus) and modulus > 0 do
    min(modulus, 65_536)
  end

  defp normalize_modulus(_), do: @default_shard_modulus

  defp normalize_message_cursor(%{created_at: created_at, id: id}) do
    {normalize_datetime!(created_at), id}
  end

  defp normalize_message_cursor(%{created_at: created_at}) do
    {normalize_datetime!(created_at), nil}
  end

  defp normalize_message_cursor(%DateTime{} = created_at),
    do: {normalize_datetime!(created_at), nil}

  defp normalize_message_cursor(%NaiveDateTime{} = created_at),
    do: {normalize_datetime!(created_at), nil}

  defp normalize_message_cursor(value) when is_binary(value),
    do: {normalize_datetime!(value), nil}

  defp normalize_message_cursor(_), do: raise(ArgumentError, "invalid cursor")

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

  ## Runtime helpers (per-thread GenServer layer)

  def ensure_thread_runtime(thread_id) when is_binary(thread_id) do
    ThreadServer.ensure(thread_id)
  end

  def dispatch_message(attrs, opts \\ []) when is_map(attrs) do
    thread_id = thread_id_from_attrs(attrs)
    ThreadServer.send_message(thread_id, attrs, opts)
  end

  def tick_thread(thread_id, participant_id, cursor \\ nil, opts \\ []) do
    ThreadServer.tick(thread_id, participant_id, cursor, opts)
  end

  def participant_in_thread?(thread_id, participant_id)
      when is_binary(thread_id) and is_binary(participant_id) do
    Participant
    |> where([p], p.thread_id == ^thread_id and p.participant_id == ^participant_id)
    |> Repo.exists?()
  end

  defp thread_id_from_attrs(attrs) do
    cond do
      Map.has_key?(attrs, :thread_id) -> Map.fetch!(attrs, :thread_id)
      Map.has_key?(attrs, "thread_id") -> Map.fetch!(attrs, "thread_id")
      true -> raise KeyError, message: "thread_id is required"
    end
  end
end
